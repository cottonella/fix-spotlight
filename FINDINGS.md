# 🔬 Findings

<p><sub>The story behind <a href="README.md">Fix-Spotlight</a>: what was broken, how we found out, what we got wrong along the way, and why the tool does what it does. If you just want your wallpaper back, the README is the place to start.</sub></p>

## The symptom

A Windows 11 machine (build 26100.9168, CBS package `1000.26100.344.0`) had **Windows spotlight** selected as its desktop background, and the desktop never changed. The wallpaper path told the first part of the story on its own:

```
C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_...\DesktopSpotlight\Assets\Images\image_2.jpg
```

That file is not a downloaded photo. It is one of four placeholders that ship inside the Spotlight package, listed in a registry value called `DefaultCreatives` and selected by `Creatives\ImageIndex`. Seeing it as the wallpaper means one thing: **nothing has ever been fetched.**

Toggling the background setting off and on, signing out and in, `DISM /RestoreHealth`, `SFC` — none of it moved the picture. The image was clean; the machine simply wasn't fetching.

## Finding the right pipeline

Almost every guide for a stuck Spotlight points at `ContentDeliveryManager` — its subscriptions, its `Renderers` key, deleting its package folder. The most useful early move was to stop guessing and compare against a **second machine, same edition, same build, where Spotlight worked**. On that healthy machine, CDM's subscription state hadn't been touched in two months. Whatever delivers the desktop wallpaper on 24H2, it isn't CDM.

It is the `MicrosoftWindows.Client.CBS` system package, through two of its applications — **`DesktopSpotlight`** and **`IrisService`** — running as WinRT background tasks. Content comes from Microsoft's Iris service (`fd.api.iris.microsoft.com`, placement `88000820`); downloaded images land under `%LOCALAPPDATA%\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\LocalCache\Microsoft\IrisService\`; per-user state lives under `HKCU\…\CurrentVersion\DesktopSpotlight` and `…\IrisService`. That placement is not tied to a country, by the way — region, locale and display size travel as parameters in a request Windows builds from the machine itself, which is why the tool never hardcodes a region and simply reuses the machine's own cached request when it probes the service.

## The root cause

Comparing configuration surfaces between the two machines turned up nothing: policies, feature flags (about 2 700 override entries on *both* — normal for 24H2, not a sign of a modified image), package integrity, binaries and signatures, the StateRepository entries for both apps, permissions, telemetry, licensing, firewall. Identical. Which is precisely why this class of problem eats hours: every static check passes.

What settled it was **watching the machine run** rather than reading its configuration. With the background-task infrastructure traced for three minutes across a maintenance run, a Spotlight re-selection and an Explorer restart, only two background tasks activated on the whole system — neither of them Spotlight's. The CBS package had **no registered background tasks at all**. No registration, no trigger, no fetch, no picture. Everything else was a consequence of that one fact.

How do they go missing? The registrations are created by the package's *configuration tasks*, which run when the package is configured for a user. `Add-AppxPackage -Register` completes successfully and changes nothing; `Reset-AppxPackage` wipes the package's local state (Start menu layout, search index) but the configuration step does not run again afterwards. The well-meaning "reset and re-register Spotlight" repair that appears in every forum thread is the most likely way to *arrive* at this break, not to leave it.

## Getting back inside

Registering a background task for someone else's package is not something a normal process can do. The task classes only resolve when the calling process carries the package's own identity — specifically the `Global.DesktopSpotlight` or `Global.IrisService` application. From anywhere else, `RoGetActivationFactory` answers `REGDB_E_CLASSNOTREG`; from inside, `S_OK`.

`Invoke-CommandInDesktopPackage` (the Appx module, no admin rights required) runs a process under exactly that identity. The tool passes its snippet as an `-EncodedCommand` and collects the output over a named pipe. Inside, the ordinary `BackgroundTaskBuilder` API registers the stock tasks, and once the package's own `BackgroundTaskManager` runs even once, it **re-registers its entire task set itself** with its own intervals — the daily `UpdateTimer`, the `Maintenance` task, the `RegistrationStatusCheck` that runs at sign-in, and the WNS `NotificationHandler` the tool never registers at all. That first run comes from the 15‑minute timer the tool registered, so it lands 15–30 minutes after a repair, and it happens even when the 60‑minute gate stops it from rotating: a health check in that window shows 7 of 8 tasks, which is the expected in-between state, not a fault.

The first time this ran, the desktop changed within the hour. The fix looked done.

## The fix that only worked once

It wasn't. The tool's "fire the timer now" step used an `ApplicationTrigger` — the one trigger type an application can raise on demand — pointed at the `UpdateTimer` entry point. It returned `Allowed`, and the wallpaper had changed. Cause and effect, apparently.

Later, on a machine with the tasks correctly registered, the same step did nothing. Three runs in a row: `Allowed`, wait, no change. What followed was a sequence of plausible explanations, each of which turned out to be wrong, and each of which is worth recording because they are exactly what anyone would try next.

**Maybe the cache is fresh, so it declines to fetch.** The 88000820 cache entry was actually already past its `LastExpiration`. Clearing it entirely and firing again changed nothing. (And the one genuinely successful run had happened with a stale cache still present — so a full cache was never what suppressed a fetch.)

**Maybe a sign-out will re-initialise it.** It didn't; the wallpaper stayed on the placeholder.

**Maybe it's power policy** — background work is "allowed subject to system policy", and this was a laptop. Energy Saver was off, on AC, 100 %.

**Maybe it's the 60-minute gate.** This one was real, and it is described below, because it matters. But opening it wide and firing again *still* changed nothing.

At that point the only honest move was to stop reasoning and look again.

## The trace that settled it

An ETW trace of the `DesktopSpotlight` and `IrisService` providers, captured across a fire, showed the whole thing: **zero events from either component.** The request was accepted and the task never ran. Not "ran and bailed" — never started.

Rereading the trace from the one success made the rest fall into place. Its first line, `BackgroundTaskManager::TaskTriggered trigger=0`, was stamped **23 seconds** after the process that raised the `ApplicationTrigger` had appeared. Application triggers fire immediately. But the registration step, minutes earlier, had also created the `UpdateTimer` task with a **15-minute `TimeTrigger`** — and Windows fires time triggers on coarse fifteen-minute boundaries, typically 15–30 minutes after registration. That is what fired. The app-trigger request happened to land next to it. Then the package re-registered `UpdateTimer` as a **1440-minute** timer, the fifteen-minute one was gone, and the coincidence could never repeat.

The entry point is declared for timer and system triggers only. Windows accepts an `ApplicationTrigger` request for it and quietly discards it every time.

So the tool now does deliberately what once happened by accident: it registers **one extra, one-shot 15-minute `TimeTrigger`** on the `UpdateTimer` entry point. Windows runs the real task itself — observed at +17.7 and +22 minutes — does the fetch, downloads the set, applies a picture, and the one-shot removes itself. Fifteen minutes is the floor for time triggers, so the tool is honest about the wait rather than pretending it can be instant.

## The 60-minute gate

Buried in the successful trace is the line that explains why so many attempts *looked* dead:

```
RefreshAllowed: refreshAllowed=1 … (now - lastWallpaperUpdateTime)=105 s_rotationPeriod=60
RefreshAllowed: refreshAllowed=0 … (now - lastWallpaperUpdateTime)=2   s_rotationPeriod=60
```

`UpdateTimer` refuses to rotate within **60 minutes** of the last time the wallpaper was touched (`WallpaperRefresh`, with `Rotation` alongside it, under `HKCU\…\DesktopSpotlight`). The constant is the component's own; the elapsed values are minutes. A refused run is still a run: it stamps `UpdateTimer` and `LastBackgroundTaskRunDate`, refreshes IrisService's provider records, and re-registers the task set — it just doesn't rotate or download. (An earlier draft of these notes claimed a gated run "writes nothing"; that was wrong. The runs that wrote nothing were the `ApplicationTrigger` requests, which never started at all.)

The gate gets restamped by Spotlight's `Maintenance` task when it re-applies the current picture — even when that picture is the placeholder — on its own roughly-daily timer. Nothing the user does at the desktop moves it: signing out and back in and locking/unlocking the screen were both tested and left every timestamp untouched. (An earlier suspicion that Win+L restamped it turned out to be the maintenance timer firing at a coincidental moment — a useful reminder that a timestamp coinciding with your action is not evidence your action caused it.)

Two more things the healthy machine's history showed about *when* the picture changes. The daily `UpdateTimer` run is the one that downloads content; but the picture can also advance at sign-in, when `RegistrationStatusCheck` runs with the gate open and the cached set still has unused images. So "once a day" is the floor, not a promise.

Backdating those two timestamps would open the gate instantly, and it works. The tool deliberately does not do it: that is Windows' rule, and the right behaviour is to say so — "the gate opens at 23:27; run this again after that" — rather than to edit the clock.

## "Today's image"

One more idea that seemed obviously right: ask the Iris service what it is serving right now, and compare it with the picture on the desktop, to tell whether a newer one is waiting. Five consecutive live requests returned five entirely different sets of four photographs. The service hands out a **shuffled pool** on every call. Nothing fetched live can be called "today's image", and nothing about it says whether *this* machine's picture is current. The health check therefore reports only that the service is reachable, and makes no claims about content.

A related nuance about the cache: while the cached set is still valid (refresh roughly every 24 hours, expiry after about 14 days), a run **rotates within the set** — the image counter climbs, the "last content retrieval" time does not. A new download from Microsoft happens when the cache is stale or expired. Both are correct behaviour; a `-Force` run always gets a new picture, and it is a freshly downloaded one when Windows' own refresh is due.

## Things that looked like the cause and weren't

For the benefit of anyone diffing their own machine, these were all present on the healthy machine too, or shown irrelevant by trace:

`Settings\SpotlightDisabledReason = 100` · `ContentDeliveryAllowed = 0` · CBS missing from `BackgroundAccessApplications` · an older CBS version listed under `AppModel\Repository\Packages` · `SoftLandingTriggerTask` in a disabled state · CloudStore `0x80070520` errors · the volume of `FeatureManagement\Overrides` entries · Energy Saver and background-app toggles · Group Policy and MDM values · `DISM` and `SFC` results. The lock screen on this edition does not offer Spotlight at all — the same on the healthy machine, so that is the SKU, not a fault.

## What it meant for the tool

Every design choice in `Fix-Spotlight.ps1` traces back to one of the paragraphs above. Register the stock tasks from inside the package, because that is the only place it can be done. Schedule the fetch with Windows' own `TimeTrigger` and wait for it honestly, because the instant trigger is a mirage. Read the 60-minute gate and report the exact time it opens instead of firing into it or rewriting it. Leave the cache alone, because clearing it was never what made a fetch happen. Make no claims about what "today's" picture is, because the service doesn't have one. And score the health verdict only on the things that actually deliver the wallpaper, so that the long list of values that merely *look* wrong never turns a healthy machine amber.

---

### Appendix: quick reference

| | |
|---|---|
| **Package** | `MicrosoftWindows.Client.CBS_cw5n1h2txyewy` — apps `Global.DesktopSpotlight`, `Global.IrisService` |
| **Content endpoint** | `https://fd.api.iris.microsoft.com/v4/api/selection?…&placement=88000820…` |
| **Images** | `%LOCALAPPDATA%\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\LocalCache\Microsoft\IrisService\<hash>\*.jpg` |
| **State** | `HKCU\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight` (`State`, `UpdateTimer`, `Rotation`, `WallpaperRefresh`, `DefaultCreatives`, `Creatives\ImageIndex`) and `…\IrisService\Cache\<id>` (`RequestUri`, `RawJson`, `LastExpiration`) |
| **Placeholders** | `C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_…\DesktopSpotlight\Assets\Images\image_0..3.jpg` |
| **Core tasks (8)** | `DesktopSpotlight.BackgroundTask.{UpdateTimer, Maintenance, RegistrationStatusCheck, OnlineIdChange}`, `IrisService.BackgroundTask.{UpdateTimer, Maintenance, OnlineIdChange, NotificationHandler}` |
| **ETW providers** | DesktopSpotlight `{95187a86-af34-505e-c26d-f6b7d6a8e0de}` · IrisService `{b84eb1f9-e572-5b45-34ab-56cdf25a2a85}` · BackgroundTaskInfrastructure `{0657adc1-9ae8-4e18-a4b0-f0a1e6e3e4c4}` |
| **Gate** | `s_rotationPeriod = 60` minutes since `WallpaperRefresh` / `Rotation` |
| **Timer floor** | `TimeTrigger` minimum 15 minutes; fires on coarse boundaries (observed +17.7 and +22 min) |
