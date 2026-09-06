<#
.SYNOPSIS
  Repairs (or health-checks) Windows Spotlight desktop background when the CBS package
  has lost its background-task registrations - the "stuck on the bundled image_N.jpg" failure.

.DESCRIPTION
  Symptom : Settings shows "Windows spotlight" selected, but the desktop never changes and
            the wallpaper path is C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_...\
            DesktopSpotlight\Assets\Images\image_N.jpg (a shipped placeholder).
  Cause   : MicrosoftWindows.Client.CBS has no registered background tasks, so
            DesktopSpotlight.BackgroundTask.UpdateTimer never runs and nothing is fetched.
  Fix     : register the tasks from INSIDE the package under the correct application
            identity (Global.DesktopSpotlight / Global.IrisService) via the normal WinRT
            BackgroundTaskBuilder API, check that the 60-minute refresh gate is open (the
            timer is ignored within 60 min of the last wallpaper touch), then schedule a
            ONE-SHOT 15-minute TimeTrigger on the UpdateTimer entry point. Windows runs the
            real task itself within ~15-30 min and the one-shot removes itself. (An
            ApplicationTrigger is accepted - RequestAsync says Allowed - but never activates
            this timer-declared task; verified by ETW trace.) CBS then takes over and
            re-registers everything with its own daily interval.

  Creates NO temporary files: in-package code is passed via -EncodedCommand and its output
  is marshaled back over a named pipe. Run in Windows PowerShell 5.1 (powershell.exe); no
  administrator rights required. Tested on Windows 11 IoT Enterprise LTSC 2024 (26100),
  CBS 1000.26100.344.0.

.PARAMETER HealthCheck
  Read-only. Print a minimal itemized health report (each indicator a colored dot) plus an
  overall verdict, and change nothing. Exit: 0 HEALTHY, 1 DEGRADED, 2 BROKEN. Alias -DiagnoseOnly.
.PARAMETER Force
  Register/fire even if UpdateTimer is already registered (use when tasks exist but the
  wallpaper is still the placeholder). Like the plain repair, it first checks DesktopSpotlight's
  60-minute refresh gate: UpdateTimer refuses to rotate within 60 min of the last wallpaper
  touch (WallpaperRefresh / Rotation), so if the gate is closed the script does not fire and
  prints the time it opens. It never rewrites those stamps.
.PARAMETER CleanLockScreenPin
  If a third-party app (e.g. "Dynamic Theme") left a pinned lock-screen image behind,
  remove those values (the removed values are printed to the console first).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Fix-Spotlight.ps1 -HealthCheck
  powershell -ExecutionPolicy Bypass -File .\Fix-Spotlight.ps1
.EXAMPLE
  # straight from GitHub (Windows PowerShell 5.1):
  irm https://raw.githubusercontent.com/cottonella/fix-spotlight/main/Fix-Spotlight.ps1 | iex
  iex "& { $(irm https://raw.githubusercontent.com/cottonella/fix-spotlight/main/Fix-Spotlight.ps1) } -HealthCheck"
#>
[CmdletBinding()]
param(
  [Alias('DiagnoseOnly')]
  [switch]$HealthCheck,
  [switch]$Force,
  [switch]$CleanLockScreenPin
)

$ErrorActionPreference = 'Continue'
$PFN = 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}   # for the dot / rule glyphs
$SEP = [string][char]0x00B7   # middot separator  (built at runtime so the source stays pure ASCII)
$ELL = [string][char]0x2026   # ellipsis

function Say ($m){ Write-Host $m }
function Ok  ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Bye ([int]$code){
  # Run as a file (-File): a real exit, so the process exit code is the verdict.
  # Piped through 'irm ... | iex' (no $PSCommandPath): 'exit' would close the user's window,
  # so just record the code in $LASTEXITCODE; the caller follows with 'return'.
  if ($PSCommandPath) { exit $code } else { $global:LASTEXITCODE = $code }
}
function Info($m){ Write-Host "  [..]   $m" -ForegroundColor Gray }

# ---- in-package call: run $Body (which emits output via W "...") under $AppId's identity,
#      deliver the script by -EncodedCommand and get its output back over a named pipe.
#      No files are written anywhere. Returns the emitted lines, or $null on failure.
function Invoke-InPackage {
  param([string]$AppId, [string]$Body, [int]$TimeoutSec = 60)
  $pipe = 'SpotlightFix_' + [guid]::NewGuid().ToString('N')
  $prologue = '$__buf = New-Object System.Collections.ArrayList; function W($s){ [void]$__buf.Add([string]$s) }'
  $epilogue = @'
try {
  $__cli = New-Object System.IO.Pipes.NamedPipeClientStream('.', '__PIPE__', [System.IO.Pipes.PipeDirection]::Out)
  $__cli.Connect(15000)
  $__wr = New-Object System.IO.StreamWriter($__cli)
  $__wr.Write(($__buf -join [char]10)); $__wr.Flush(); $__wr.Dispose(); $__cli.Dispose()
} catch {}
'@
  $full = $prologue + "`n" + $Body + "`n" + $epilogue.Replace('__PIPE__', $pipe)
  $enc  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
  $srv  = New-Object System.IO.Pipes.NamedPipeServerStream($pipe, [System.IO.Pipes.PipeDirection]::In, 1, `
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
  try {
    Invoke-CommandInDesktopPackage -PackageFamilyName $PFN -AppId $AppId -Command 'powershell.exe' `
      -Args "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc" -ErrorAction Stop
  } catch { Bad "Invoke-CommandInDesktopPackage failed for $AppId : $($_.Exception.Message)"; $srv.Dispose(); return $null }
  $iar = $srv.BeginWaitForConnection($null, $null)
  if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) { try { $srv.Dispose() } catch {}; return $null }
  try {
    $srv.EndWaitForConnection($iar)
    $rdr  = New-Object System.IO.StreamReader($srv)
    $data = $rdr.ReadToEnd(); $rdr.Dispose()
  } catch { try { $srv.Dispose() } catch {}; return $null }
  try { $srv.Dispose() } catch {}
  if ($null -eq $data) { return @() }
  return ($data -split "`n")
}

function Get-SpotlightState {
  $k  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight')
  $st = if ($k) { "$($k.GetValue('State'))" -replace '\s+',' ' } else { '' }
  $la = if ($st -match 'LastAttemptDate":"([^"]+)') { $Matches[1] } else { '' }
  $ss = ($st -match 'RetrieveIrisContentSuccess":true')
  $sd = if ($st -match 'RetrieveIrisContentSuccessDate":"([^"]+)') { $Matches[1] } else { '' }
  $cache = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\IrisService\Cache'
  $c820 = @(Get-ChildItem $cache -ErrorAction SilentlyContinue | Where-Object {
            "$((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RequestUri)" -match 'placement=88000820' })
  $cExpiry=''; $cExpired=$false; $cHasImg=$false; $cStatus=''; $cUri=''; $cRefresh=''
  if ($c820.Count) {
    $cv = Get-ItemProperty $c820[0].PSPath -ErrorAction SilentlyContinue
    $cStatus = $cv.StatusCode; $cExpiry = $cv.LastExpiration; $cUri = "$($cv.RequestUri)"; $cRefresh = "$($cv.RefreshTime)"
    if ($cExpiry) { try { $cExpired = ([DateTime]::Parse($cExpiry).ToUniversalTime() -lt [DateTime]::UtcNow) } catch {} }
    $cHasImg = ("$($cv.RawJson)" -match 'landscapeImage|portraitImage|onecdn')
  }
  $iris = "$env:LOCALAPPDATA\Packages\$PFN\LocalCache\Microsoft\IrisService"
  $allImg = @(Get-ChildItem $iris -Recurse -File -ErrorAction SilentlyContinue)
  [pscustomobject]@{
    BackgroundType   = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -ErrorAction SilentlyContinue).BackgroundType
    Wallpaper        = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
    IsFallback       = ((Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper -match '\\SystemApps\\.*\\DesktopSpotlight\\Assets\\Images\\image_\d+\.jpg$')
    UpdateTimer      = if ($k) { $k.GetValue('UpdateTimer') } else { $null }
    Rotation         = if ($k) { $k.GetValue('Rotation') } else { $null }
    WallpaperRefresh = if ($k) { $k.GetValue('WallpaperRefresh') } else { $null }
    ImagesUsed       = if ($k) { $k.GetValue('ImagesUsed') } else { $null }
    LastAttempt      = $la
    StateSuccess     = $ss
    StateSuccessDate = $sd
    Cache820         = $c820.Count
    Cache820Status   = $cStatus
    Cache820Expiry   = $cExpiry
    Cache820Expired  = $cExpired
    Cache820HasImg   = $cHasImg
    Cache820Uri      = $cUri
    Cache820Refresh  = $cRefresh
    IrisFiles        = $allImg.Count
    IrisFullSize     = @($allImg | Where-Object { $_.Length -gt 100kb }).Count
  }
}

# ------------------------------------------------------------ 0. preflight ----
if (-not $HealthCheck) { Say ""; Say "=== Fix-Spotlight :: $env:COMPUTERNAME :: $(Get-Date) ===" }
if ($PSVersionTable.PSEdition -ne 'Desktop') { Bad "Run this in Windows PowerShell 5.1 (powershell.exe), not pwsh - WinRT projection is required."; Bye 2; return }
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cbs = Get-AppxPackage -Name 'MicrosoftWindows.Client.CBS' -ErrorAction SilentlyContinue
if (-not $cbs) { Bad "MicrosoftWindows.Client.CBS is not registered for this user - this fix does not apply."; Bye 2; return }
if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) { Bad "Invoke-CommandInDesktopPackage (Appx module) not available."; Bye 2; return }
if (-not $HealthCheck) {
  Info "$($cv.ProductName) / $($cv.EditionID) / build $($cv.CurrentBuild).$($cv.UBR)"
  Ok "CBS package $($cbs.Version) status=$($cbs.Status)"
}

$s0 = Get-SpotlightState
if (-not $HealthCheck) {
  Say ""
  Say "--- current state ---"
  Info "BackgroundType = $($s0.BackgroundType)   (3 = Windows spotlight)"
  Info "Wallpaper      = $($s0.Wallpaper)"
  if ($s0.IsFallback) { Warn "Desktop is showing the bundled PLACEHOLDER image - nothing has ever been fetched." } else { Ok "Wallpaper is not the placeholder." }
  Info "UpdateTimer last ran   : $(if ($s0.UpdateTimer) { $s0.UpdateTimer } else { '(never)' })"
  Info "88000820 cache entries : $($s0.Cache820)   downloaded images: $($s0.IrisFiles)"
  if ($s0.BackgroundType -ne 3) { Warn "Desktop background is not set to Windows spotlight. Select it in Settings > Personalization > Background; the tasks only do work while it is selected." }
}

# lock-screen pin left by a third-party app (e.g. Dynamic Theme)
$ls = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen'
$pin = @()
foreach ($slot in 'A','B','C') {
  $d = (Get-ItemProperty $ls -Name "Details_$slot" -ErrorAction SilentlyContinue)."Details_$slot"
  if ($d -and $d -match 'APPID:' -and $d -notmatch 'Microsoft\.') { $pin += $slot; if (-not $HealthCheck) { Warn "Lock screen pinned by third-party app (slot $slot): $d" } }
}
if ($pin -and $CleanLockScreenPin -and -not $HealthCheck) {
  foreach ($slot in $pin) {
    foreach ($v in "ImageId_$slot","Details_$slot","OriginalFile_$slot") {
      $cur = (Get-ItemProperty $ls -Name $v -ErrorAction SilentlyContinue).$v
      if ($null -ne $cur) { Info "removing $v = $cur" }
      Remove-ItemProperty -Path $ls -Name $v -ErrorAction SilentlyContinue
    }
  }
  Ok "Removed pinned lock-screen values (printed above for your records)."
} elseif ($pin -and -not $HealthCheck) { Info "Re-run with -CleanLockScreenPin to remove it." }

# ------------------------------------------------ 1. enumerate (in-package) ---
$EnumBody = @'
try { $ai=[Windows.ApplicationModel.AppInfo,Windows.ApplicationModel,ContentType=WindowsRuntime]::Current; W "AUMID=$($ai.AppUserModelId)" } catch { W "AUMID=?" }
$rt=[Windows.ApplicationModel.Background.BackgroundTaskRegistration,Windows.ApplicationModel,ContentType=WindowsRuntime]
foreach($kv in $rt::AllTasks){ W "TASK=$($kv.Value.Name)" }
try { W "ACCESS=$([Windows.ApplicationModel.Background.BackgroundExecutionManager,Windows.ApplicationModel,ContentType=WindowsRuntime]::GetAccessStatus())" } catch {}
'@
if (-not $HealthCheck) { Say ""; Say "--- registered background tasks (read from inside the package) ---" }
$enum = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $EnumBody -TimeoutSec 40
if (-not $enum) { Bad "Could not enumerate tasks inside the package."; Bye 2; return }
$aumid  = ($enum | Where-Object { $_ -like 'AUMID=*' }) -replace '^AUMID=',''
$tasks  = @($enum | Where-Object { $_ -like 'TASK=*' } | ForEach-Object { $_ -replace '^TASK=','' })
$access = ($enum | Where-Object { $_ -like 'ACCESS=*' }) -replace '^ACCESS=',''
# Right after a logon the broker can transiently surface 0 tasks to a fresh activation; re-read once.
if ($tasks.Count -eq 0 -and $aumid -like "*!Global.DesktopSpotlight") {
  if (-not $HealthCheck) { Info "0 tasks on first read (can happen right after logon) - re-checking in 20s..." }
  Start-Sleep -Seconds 20
  $enum = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $EnumBody -TimeoutSec 40
  $tasks  = @($enum | Where-Object { $_ -like 'TASK=*' } | ForEach-Object { $_ -replace '^TASK=','' })
  $access = ($enum | Where-Object { $_ -like 'ACCESS=*' }) -replace '^ACCESS=',''
}
if ($aumid -notlike "*!Global.DesktopSpotlight") { Bad "Package identity not acquired (AUMID='$aumid')."; Bye 2; return }
$hasUpdateTimer = $tasks -contains 'DesktopSpotlight.BackgroundTask.UpdateTimer'
if (-not $HealthCheck) {
  Info "AUMID  : $aumid"
  Info "Access : $access"
  Info "Tasks  : $($tasks.Count)"
  $tasks | Sort-Object | ForEach-Object { Info "         $_" }
  if ($hasUpdateTimer) { Ok "DesktopSpotlight.BackgroundTask.UpdateTimer is registered." } else { Warn "DesktopSpotlight.BackgroundTask.UpdateTimer is NOT registered - this is the failure this script fixes." }
}

# --------------------------------------------------- health report (read-only) ---
if ($HealthCheck) {
  $script:fails = 0; $script:warns = 0
  $LBLW = 26
  function Head($t){
    Write-Host ""
    Write-Host ("  " + $t.ToUpper()) -ForegroundColor DarkGray -NoNewline
    Write-Host ("  " + ([string]([char]0x2500) * [Math]::Max(4, 46 - $t.Length))) -ForegroundColor DarkGray
  }
  function Chk($label,$state,$detail){
    switch ($state) {
      'PASS' { $glyph=[char]0x25CF; $gc='Green'  }
      'WARN' { $glyph=[char]0x25CF; $gc='Yellow'; $script:warns++ }
      'FAIL' { $glyph=[char]0x25CF; $gc='Red';    $script:fails++ }
      'NOTE' { $glyph=[char]0x25CF; $gc='Yellow' }     # amber for attention, but NOT scored
      default{ $glyph=[char]0x25CB; $gc='DarkGray' }   # INFO
    }
    Write-Host "  " -NoNewline
    Write-Host $glyph -ForegroundColor $gc -NoNewline
    Write-Host ("  " + ([string]$label).PadRight($LBLW) + "  ") -ForegroundColor Gray -NoNewline
    Write-Host ([string]$detail) -ForegroundColor $(if ($state -eq 'INFO' -or $state -eq 'NOTE') { 'DarkGray' } else { 'White' })
  }
  function Ago($iso){   # "(2h ago)" / "(in 14d)" relative to now, for absolute UTC stamps
    if (-not $iso) { return '' }
    try { $t=[DateTime]::Parse($iso).ToUniversalTime(); $d=[DateTime]::UtcNow - $t } catch { return '' }
    $fut=$d.TotalSeconds -lt 0; $s=[Math]::Abs($d.TotalSeconds)
    $txt = if($s -lt 90){'{0:n0}s' -f $s} elseif($s -lt 5400){'{0:n0}m' -f ($s/60)} elseif($s -lt 129600){'{0:n0}h' -f ($s/3600)} else {'{0:n0}d' -f ($s/86400)}
    if($fut){"(in $txt)"}else{"($txt ago)"}
  }
  Write-Host ""
  Write-Host "  spotlight health" -ForegroundColor Cyan -NoNewline
  Write-Host ("  " + $SEP + "  " + $env:COMPUTERNAME) -ForegroundColor DarkGray
  $osShort = ($cv.ProductName -replace '^Windows( 1[01])? ','')
  Write-Host ("  " + $osShort + " " + $SEP + " " + $cv.CurrentBuild + "." + $cv.UBR + " " + $SEP + " CBS " + $cbs.Version + " " + $SEP + " checked " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray

  Head 'critical'
  Chk 'CBS package'            'PASS' "$($cbs.Version) $SEP $($cbs.Status)"
  Chk 'Package identity'       $(if($aumid -like '*!Global.DesktopSpotlight'){'PASS'}else{'FAIL'}) "$ELL!$($aumid -replace '.*!','')"
  Chk 'UpdateTimer registered' $(if($hasUpdateTimer){'PASS'}else{'FAIL'}) $(if($hasUpdateTimer){'yes'}else{'MISSING - core failure'})
  if ($s0.BackgroundType -eq 3) {
    Chk 'Wallpaper is real image' $(if($s0.IsFallback){'FAIL'}else{'PASS'}) $(if($s0.IsFallback){'placeholder image_N.jpg'}else{Split-Path $s0.Wallpaper -Leaf})
  } else {
    Chk 'Wallpaper is real image' 'INFO' 'n/a - spotlight not selected'
  }
  $polHits = @()
  foreach ($p in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','HKCU:\Software\Policies\Microsoft\Windows\CloudContent') {
    foreach ($v in 'DisableWindowsSpotlightFeatures','DisableSpotlightCollectionOnDesktop','DisableThirdPartySuggestions','DisableWindowsConsumerFeatures') {
      if ((Get-ItemProperty $p -Name $v -ErrorAction SilentlyContinue).$v -eq 1) { $polHits += "$v=1" }
    }
  }
  foreach ($v in 'AllowWindowsSpotlight','AllowSpotlightCollection','AllowWindowsConsumerFeatures') {
    if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Experience' -Name $v -ErrorAction SilentlyContinue).$v -eq 0) { $polHits += "$v=0(MDM)" }
  }
  $hardBlock = @($polHits | Where-Object { $_ -match 'DisableWindowsSpotlightFeatures|DisableSpotlightCollectionOnDesktop|AllowWindowsSpotlight=0|AllowSpotlightCollection=0' })
  Chk 'No blocking policy' $(if($hardBlock.Count){'FAIL'}elseif($polHits.Count){'WARN'}else{'PASS'}) $(if($polHits.Count){$polHits -join '; '}else{'none set'})

  Head 'important'
  $expected = @(
    'DesktopSpotlight.BackgroundTask.UpdateTimer','DesktopSpotlight.BackgroundTask.Maintenance',
    'DesktopSpotlight.BackgroundTask.RegistrationStatusCheck','DesktopSpotlight.BackgroundTask.OnlineIdChange',
    'IrisService.BackgroundTask.UpdateTimer','IrisService.BackgroundTask.Maintenance',
    'IrisService.BackgroundTask.OnlineIdChange','IrisService.BackgroundTask.NotificationHandler')
  $missing = @($expected | Where-Object { $tasks -notcontains $_ })
  Chk 'All 8 core tasks'        $(if($missing.Count){'WARN'}else{'PASS'}) $(if($missing.Count){"$(8-$missing.Count)/8 - missing $($missing -join ', ')"}else{'8/8'})
  Chk 'Background exec access'  $(if($access -match 'Allowed'){'PASS'}elseif($access -match 'Denied'){'FAIL'}else{'WARN'}) $access
  Chk 'Downloaded images'       $(if($s0.IrisFullSize -gt 0){'PASS'}else{'WARN'}) "$($s0.IrisFullSize) full-size ($($s0.IrisFiles) total)"
  Chk 'Wallpaper content cache' $(if($s0.Cache820 -and -not $s0.Cache820Expired -and $s0.Cache820HasImg){'PASS'}elseif($s0.Cache820){'WARN'}else{'WARN'}) $(if($s0.Cache820){"$($s0.Cache820Status) $SEP hasImages=$($s0.Cache820HasImg) $SEP $(if($s0.Cache820Expired){'EXPIRED'}else{'valid'})"}else{'no 88000820 entry'})
  Chk 'Last content retrieval'  $(if($s0.StateSuccess){'PASS'}else{'WARN'}) "success=$($s0.StateSuccess)$(if($s0.StateSuccessDate){' @ '+$s0.StateSuccessDate+'  '+(Ago $s0.StateSuccessDate)})"
  $helpers = @($tasks | Where-Object { $_ -match '\.(fixapp2?|pwr|net|app|rotatetest)$' })
  Chk 'No leftover helpers'     $(if($helpers.Count){'WARN'}else{'PASS'}) $(if($helpers.Count){"$($helpers.Count) leftover: $($helpers -join ', ')"}else{'clean'})

  Head 'info'
  Chk 'Background mode'      'INFO' "$($s0.BackgroundType) $(if($s0.BackgroundType -eq 3){'(Windows spotlight)'}else{'(NOT spotlight)'})"
  Chk 'Images shown so far' 'INFO' "$($s0.ImagesUsed)  (~daily on content pull, not hourly)"
  Chk 'Last wallpaper change' 'INFO' $(if($s0.Rotation){"$($s0.Rotation)  $(Ago $s0.Rotation)"}else{'(never)'})
  # CBS re-registers UpdateTimer as a 1440-min TimeTrigger on every run, so the next run is
  # anchored to the last one (+24h; Windows aligns coarsely and catches up after sleep).
  $nextRun = $null; if ($s0.UpdateTimer) { try { $nextRun = [DateTime]::Parse($s0.UpdateTimer).ToUniversalTime().AddHours(24) } catch {} }
  Chk 'Next daily run (expected)' 'INFO' $(if($nextRun){"$($nextRun.ToLocalTime().ToString('ddd HH:mm'))  $(Ago $nextRun.ToString('o'))  $SEP later if the PC was asleep; a sign-in can rotate sooner"}else{'-'})
  Chk 'Next content download'    'INFO' $(if($s0.Cache820Refresh){ $r=[DateTime]::Parse($s0.Cache820Refresh).ToUniversalTime(); "$($r.ToLocalTime().ToString('ddd HH:mm'))  $(Ago $r.ToString('o'))  $SEP until then runs rotate within the cached set" }else{'-'})
  # UpdateTimer refuses to rotate within 60 min of WallpaperRefresh / Rotation (RefreshAllowed).
  $gateNewest = $null
  foreach ($n in 'WallpaperRefresh','Rotation') {
    $v = $s0.$n; if (-not $v) { continue }
    try { $t = [DateTime]::Parse($v).ToUniversalTime(); if (-not $gateNewest -or $t -gt $gateNewest.t) { $gateNewest = [pscustomobject]@{ n=$n; t=$t } } } catch {}
  }
  if ($gateNewest -and ([DateTime]::UtcNow - $gateNewest.t).TotalMinutes -lt 60) {
    # Amber whenever closed so it is seen; scored only when it is actually blocking a repair
    # (placeholder on screen). A healthy machine is gated for 60 min after every rotation.
    Chk 'Refresh gate (60 min)' $(if($s0.IsFallback){'WARN'}else{'NOTE'}) ("closed " + $SEP + " opens " + $gateNewest.t.AddMinutes(60).ToLocalTime().ToString('HH:mm') + " ($($gateNewest.n) $(Ago $gateNewest.t.ToString('o'))) " + $SEP + $(if($s0.IsFallback){" repair must wait until then"}else{" normal after a rotation"}))
  } else {
    Chk 'Refresh gate (60 min)' 'INFO' 'open'
  }
  Chk 'Content cache expires' 'INFO' $(if($s0.Cache820Expiry){"$($s0.Cache820Expiry)  $(Ago $s0.Cache820Expiry)"}else{'-'})
  if ($tasks -contains 'DesktopSpotlight.BackgroundTask.UpdateTimer.fix15') { Chk 'Fetch scheduled' 'INFO' 'one-shot timer pending (runs within ~15-30 min of scheduling, then removes itself)' }
  # Live check: is the Spotlight service reachable? (Reachability only - the served pool is
  # shuffled per request, so its content says nothing about this machine's wallpaper.)
  # Region/locale/display are read from THIS machine - never hardcoded: we reuse the machine's
  # own cached request URL (Windows built it with the right region) and only swap in a fresh
  # request id; the no-cache fallback derives them locally.
  if ($s0.Cache820Uri) {
    $uri = $s0.Cache820Uri -replace 'asid=[0-9A-Fa-f]+', ('asid=' + [guid]::NewGuid().ToString('N').ToUpperInvariant())
  } else {
    $ctry = try { ([System.Globalization.RegionInfo]::CurrentRegion).TwoLetterISORegionName } catch { (Get-Culture).Name -replace '.*-','' }
    $loc  = (Get-Culture).Name
    $osv  = "10.0.$($cv.CurrentBuild).$($cv.UBR)"
    $uri  = "https://fd.api.iris.microsoft.com/v4/api/selection?&asid=$([guid]::NewGuid().ToString('N').ToUpperInvariant())&placement=88000820&bcnt=4&country=$ctry&locale=$loc&lc=$loc&pl=$loc&fmt=json&clr=cdmlite&devfam=Windows.Desktop&devosver=$osv"
  }
  $servedTxt = $null
  try { $servedTxt = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10).Content } catch {}
  if (-not $servedTxt)                                          { Chk 'Spotlight service (live)' 'INFO' 'could not reach Microsoft (offline?)' }
  elseif ($servedTxt -match 'landscapeImage|portraitImage|onecdn') { Chk 'Spotlight service (live)' 'INFO' 'reachable, serving wallpaper content' }
  else                                                           { Chk 'Spotlight service (live)' 'INFO' 'reachable, but no wallpaper creatives returned' }

  $vt = if ($script:fails){'BROKEN'} elseif ($script:warns){'DEGRADED'} else {'HEALTHY'}
  $vc = if ($script:fails){'Red'}    elseif ($script:warns){'Yellow'}  else {'Green'}
  Write-Host ""
  Write-Host "  " -NoNewline
  Write-Host ([string]([char]0x2589) + " ") -ForegroundColor $vc -NoNewline
  Write-Host $vt -ForegroundColor $vc -NoNewline
  Write-Host ("     $($script:fails) fail " + $SEP + " $($script:warns) warn") -ForegroundColor DarkGray
  if     ($vt -eq 'BROKEN')   { Write-Host "  run the script with no switches to repair" -ForegroundColor DarkGray }
  elseif ($vt -eq 'DEGRADED') { Write-Host "  review the amber lines above; -Force schedules a fresh fetch" -ForegroundColor DarkGray }
  Write-Host ""
  Bye $(if($script:fails){2}elseif($script:warns){1}else{0}); return
}

# fire body - schedules a ONE-SHOT 15-minute TimeTrigger on the UpdateTimer entry point.
# Windows runs the real task itself within ~15-30 min (TimeTrigger's 15-min floor plus
# coarse alignment) and the one-shot registration removes itself afterwards. An
# ApplicationTrigger is accepted (RequestAsync -> Allowed) but never activates this
# timer-declared task - verified by ETW trace (0 DesktopSpotlight events on every attempt).
$FireBody = @'
$bld=[Windows.ApplicationModel.Background.BackgroundTaskBuilder,Windows.ApplicationModel,ContentType=WindowsRuntime]
$tt =[Windows.ApplicationModel.Background.TimeTrigger,Windows.ApplicationModel,ContentType=WindowsRuntime]
$rt =[Windows.ApplicationModel.Background.BackgroundTaskRegistration,Windows.ApplicationModel,ContentType=WindowsRuntime]
$name='DesktopSpotlight.BackgroundTask.UpdateTimer.fix15'
try {
  $pending=$false
  foreach($kv in $rt::AllTasks){ if($kv.Value.Name -eq $name){ $pending=$true } }
  if($pending){ W "SCHEDULED=EXISTING" }
  else {
    $b=[Activator]::CreateInstance($bld); $b.Name=$name; $b.TaskEntryPoint='DesktopSpotlight.BackgroundTask.UpdateTimer'
    $b.SetTrigger([Activator]::CreateInstance($tt,@([uint32]15,$true)))
    $r=$b.Register(); W "SCHEDULED=$($r.TaskId)"
  }
} catch { W ("SCHEDULED=FAIL hr=0x{0:X8} {1}" -f $_.Exception.HResult,($_.Exception.Message -replace '\s+',' ')) }
'@

if ($hasUpdateTimer -and -not $Force) {
  Say ""
  if ($s0.IsFallback) { Warn "Tasks are registered but the wallpaper is still the placeholder. Re-run with -Force to schedule a fetch."; Bye 1; return }
  Ok "Nothing to do - registrations present and wallpaper is real."; Bye 0; return
}

# ---------------------------------------------------- 2. register (in-package) ---
$RegBodyTemplate = @'
$Which='__WHICH__'
$bld=[Windows.ApplicationModel.Background.BackgroundTaskBuilder,Windows.ApplicationModel,ContentType=WindowsRuntime]
$tt =[Windows.ApplicationModel.Background.TimeTrigger,Windows.ApplicationModel,ContentType=WindowsRuntime]
$st =[Windows.ApplicationModel.Background.SystemTrigger,Windows.ApplicationModel,ContentType=WindowsRuntime]
$ste=[Windows.ApplicationModel.Background.SystemTriggerType,Windows.ApplicationModel,ContentType=WindowsRuntime]
$rt =[Windows.ApplicationModel.Background.BackgroundTaskRegistration,Windows.ApplicationModel,ContentType=WindowsRuntime]
$have=@{}; foreach($kv in $rt::AllTasks){ $have[$kv.Value.Name]=$true }
if($Which -eq 'DS'){ $plan=@(
  @{n='DesktopSpotlight.BackgroundTask.UpdateTimer';kind='time';min=15},
  @{n='DesktopSpotlight.BackgroundTask.RegistrationStatusCheck';kind='sys';st='SessionConnected'},
  @{n='DesktopSpotlight.BackgroundTask.Maintenance';kind='sys';st='SessionConnected'},
  @{n='DesktopSpotlight.BackgroundTask.OnlineIdChange';kind='sys';st='OnlineIdConnectedStateChange'}) }
else { $plan=@(
  @{n='IrisService.BackgroundTask.UpdateTimer';kind='time';min=15},
  @{n='IrisService.BackgroundTask.Maintenance';kind='sys';st='SessionConnected'},
  @{n='IrisService.BackgroundTask.OnlineIdChange';kind='sys';st='OnlineIdConnectedStateChange'}) }
foreach($p in $plan){
  if($have.ContainsKey($p.n)){ W "SKIP=$($p.n)"; continue }
  try{
    $b=[Activator]::CreateInstance($bld); $b.Name=$p.n; $b.TaskEntryPoint=$p.n
    if($p.kind -eq 'time'){ $trig=[Activator]::CreateInstance($tt,@([uint32]$p.min,$false)) }
    else { $trig=[Activator]::CreateInstance($st,@([Enum]::Parse($ste,$p.st),$false)) }
    $b.SetTrigger($trig); $null=$b.Register(); W "OK=$($p.n)"
  } catch { W ("FAIL={0} hr=0x{1:X8} {2}" -f $p.n,$_.Exception.HResult,($_.Exception.Message -replace '\s+',' ')) }
}
'@
Say ""
Say "--- registering background tasks ---"
foreach ($ctx in @(@{app='Global.DesktopSpotlight';which='DS'}, @{app='Global.IrisService';which='IRIS'})) {
  $out = Invoke-InPackage -AppId $ctx.app -Body ($RegBodyTemplate.Replace('__WHICH__',$ctx.which)) -TimeoutSec 45
  if ($null -eq $out) { Bad "no result from $($ctx.app)"; continue }
  $out | ForEach-Object {
    if     ($_ -like 'OK=*')   { Ok   ("registered " + ($_ -replace '^OK=','')) }
    elseif ($_ -like 'SKIP=*') { Info ("already present " + ($_ -replace '^SKIP=','')) }
    elseif ($_ -like 'FAIL=*') { Bad  ($_ -replace '^FAIL=','') }
  }
}

# ------------------------------------ 2b. is the 60-minute refresh gate open? ---
# UpdateTimer runs RefreshAllowed first and refuses to rotate within s_rotationPeriod
# (60 min, from DesktopSpotlight's own trace) of the last wallpaper touch (WallpaperRefresh)
# or last rotation (Rotation). Maintenance restamps WallpaperRefresh on every session-connect
# (lock/unlock, sign-in), so a fire inside that window silently does nothing - and a gated
# run writes no timestamps, which makes it look like the task never ran. This script does
# NOT rewrite those stamps (that is Windows' rule); it tells you when the gate opens.
$gateOpen = $null
foreach ($n in 'WallpaperRefresh','Rotation') {
  $v = $s0.$n; if (-not $v) { continue }
  try { $t = [DateTime]::Parse($v).ToUniversalTime().AddMinutes(60); if (-not $gateOpen -or $t -gt $gateOpen) { $gateOpen = $t } } catch {}
}
if ($gateOpen -and $gateOpen -gt [DateTime]::UtcNow) {
  $wait = [int]([Math]::Ceiling(($gateOpen - [DateTime]::UtcNow).TotalMinutes))
  Say ""
  Warn "Spotlight's 60-minute refresh gate is closed (last wallpaper touch < 60 min ago) - Windows will ignore the timer until $($gateOpen.ToLocalTime().ToString('HH:mm')) ($wait min)."
  Warn "Not scheduling. Run this again any time after $($gateOpen.ToLocalTime().ToString('HH:mm')); it will schedule the fetch then."
  Bye 1; return
}

# --------------------------------- 3. schedule the fetch (in-package one-shot timer) ---
# ($FireBody is defined once, above.)
Say ""
Say "--- scheduling DesktopSpotlight.BackgroundTask.UpdateTimer (one-shot 15-min timer) ---"
$fire  = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $FireBody -TimeoutSec 60
$sched = if ($fire) { (($fire | Where-Object { $_ -like 'SCHEDULED=*' }) -replace '^SCHEDULED=','') } else { 'FAIL (no result)' }
if ($sched -like 'FAIL*') { Bad "could not register the timer -> $sched"; Bye 2; return }
if ($sched -eq 'EXISTING') { Info "a fetch is already scheduled from an earlier run - leaving its clock alone" }
else { Ok "registered (id $sched); the one-shot removes itself after it runs" }
$eta0 = (Get-Date).AddMinutes(15); $eta1 = (Get-Date).AddMinutes(30)
Info ("Windows runs the fetch itself between ~{0} and ~{1} (TimeTrigger's 15-min floor plus alignment). Locking, signing out or rebooting do not disturb it." -f $eta0.ToString('HH:mm'), $eta1.ToString('HH:mm'))

# ---------------------------------------------------------------- 4. verify ---
Say ""
Say "--- waiting for Windows to run it (usually 15-30 min; Ctrl+C is safe - the timer stays scheduled) ---"
$before = $s0.Wallpaper; $deadline = (Get-Date).AddMinutes(35); $s1 = $s0; $tick = Get-Date
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 15
  $s1 = Get-SpotlightState
  if ($s1.Wallpaper -ne $before -and -not $s1.IsFallback) { break }
  if (((Get-Date) - $tick).TotalSeconds -ge 60) { Info ("{0}  still waiting - wallpaper unchanged" -f (Get-Date).ToString('HH:mm')); $tick = Get-Date }
}
Say ""
Say "--- result ---"
Info "UpdateTimer last ran   : $($s1.UpdateTimer)"
Info "88000820 cache entries : $($s1.Cache820)   downloaded images: $($s1.IrisFiles)"
Info "Wallpaper              : $($s1.Wallpaper)"
Say ""
if ($s1.Wallpaper -ne $before -and -not $s1.IsFallback) {
  Ok "FIXED. Spotlight fetched content and set a downloaded image. CBS keeps its own daily timer from here on. Re-run with -HealthCheck any time."
  Bye 0; return
} else {
  Bad "The timer did not rotate the wallpaper within 35 min. Run -HealthCheck: 'Background exec access' must be Allowed, 'Refresh gate' open, and the machine online."
  Bye 2; return
}
