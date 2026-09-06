<#
.SYNOPSIS
  Health-checks (default) or repairs Windows Spotlight desktop background when the CBS package
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

  Two ways to use it. With no switches it is INTERACTIVE: the health report, then a small
  menu ([M]) - health check, fix, force, remove a pending fetch - that comes back after each
  action until you press Q. With any switch it is UNATTENDED: the one action runs, nothing
  is ever prompted, and the exit code is the result.

  In-package code is passed via -EncodedCommand and its output is marshaled back over a
  named pipe. Run in Windows PowerShell 5.1 (powershell.exe); no administrator rights
  required. Tested on Windows 11 IoT Enterprise LTSC 2024 (26100), CBS 1000.26100.344.0.

.PARAMETER HealthCheck
  Read-only report, no menu prompt (the scripting-safe form of the default run). Exit:
  0 HEALTHY, 1 DEGRADED, 2 BROKEN. Alias -DiagnoseOnly.
.PARAMETER Fix
  Repair: register any missing tasks in-package, check the 60-minute refresh gate, schedule
  the one-shot fetch and wait (usually 15-30 min) for the new wallpaper. Does nothing when the
  tasks are present and the wallpaper is already a real photo (use -Force for that).
.PARAMETER Force
  Like -Fix, but also when the tasks already exist - for the "registered but still stuck on
  the placeholder" case, or to ask for a new photo. Same rules as -Fix: the fetch is a timer
  Windows runs 15-30 min later, and only if the 60-minute gate is open - if it is closed the
  script reports when it opens and stops. Never rewrites Spotlight's timestamps.
.PARAMETER RemoveFetch
  Unregister a pending one-shot fetch scheduled by an earlier -Fix / -Force.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Fix-Spotlight.ps1              # health + menu
  powershell -ExecutionPolicy Bypass -File .\Fix-Spotlight.ps1 -HealthCheck # health, no prompt
  powershell -ExecutionPolicy Bypass -File .\Fix-Spotlight.ps1 -Fix
.EXAMPLE
  # straight from GitHub (Windows PowerShell 5.1):
  irm https://raw.githubusercontent.com/cottonella/fix-spotlight/main/Fix-Spotlight.ps1 | iex
  iex "& { $(irm https://raw.githubusercontent.com/cottonella/fix-spotlight/main/Fix-Spotlight.ps1) } -Fix"
#>
[CmdletBinding()]
param(
  [Alias('DiagnoseOnly')]
  [switch]$HealthCheck,
  [switch]$Fix,
  [switch]$Force,
  [switch]$RemoveFetch
)

$ErrorActionPreference = 'Continue'
$PFN = 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}   # for the dot / rule glyphs
$SEP = [string][char]0x00B7   # middot separator  (built at runtime so the source stays pure ASCII)
$ELL = [string][char]0x2026   # ellipsis
$BLK = [string][char]0x2589   # verdict block
$LBLW = 26                    # label column width

function Bad ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Bye ([int]$code){
  # Run as a file (-File): a real exit, so the process exit code is the verdict.
  # Piped through 'irm ... | iex' (no $PSCommandPath): 'exit' would close the user's window,
  # so just record the code in $LASTEXITCODE; the caller follows with 'return'.
  if ($PSCommandPath) { exit $code } else { $global:LASTEXITCODE = $code }
}

# ---------------------------------------------------------------- presentation ---
# Every mode (health, repair, remove) speaks the same language: a header, sections of
# colored dots, and a block verdict. WARN/FAIL dots are counted into the verdict; NOTE is
# amber for attention but not scored; INFO is a hollow dot.
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
    'NOTE' { $glyph=[char]0x25CF; $gc='Yellow' }
    default{ $glyph=[char]0x25CB; $gc='DarkGray' }   # INFO
  }
  Write-Host "  " -NoNewline
  Write-Host $glyph -ForegroundColor $gc -NoNewline
  Write-Host ("  " + ([string]$label).PadRight($LBLW) + "  ") -ForegroundColor Gray -NoNewline
  Write-Host ([string]$detail) -ForegroundColor $(if ($state -eq 'INFO' -or $state -eq 'NOTE') { 'DarkGray' } else { 'White' })
}
function When($iso){  # short local form of a UTC stamp: "Sat 02:23", or "Sep 20 02:27" beyond a week
  if (-not $iso) { return '' }
  try { $t=[DateTime]::Parse($iso).ToUniversalTime().ToLocalTime() } catch { return "$iso" }
  if ([Math]::Abs(([DateTime]::Now - $t).TotalDays) -lt 6.5) { return $t.ToString('ddd HH:mm') }
  return $t.ToString('MMM d HH:mm')
}
function Ago($iso){   # "(2h ago)" / "(in 14d)" relative to now, for absolute UTC stamps
  if (-not $iso) { return '' }
  try { $t=[DateTime]::Parse($iso).ToUniversalTime(); $d=[DateTime]::UtcNow - $t } catch { return '' }
  $fut=$d.TotalSeconds -lt 0; $s=[Math]::Abs($d.TotalSeconds)
  $txt = if($s -lt 90){'{0:n0}s' -f $s} elseif($s -lt 5400){'{0:n0}m' -f ($s/60)} elseif($s -lt 129600){'{0:n0}h' -f ($s/3600)} else {'{0:n0}d' -f ($s/86400)}
  if($fut){"(in $txt)"}else{"($txt ago)"}
}
function Banner($mode){
  $script:fails = 0; $script:warns = 0
  Write-Host ""
  Write-Host ("  spotlight " + $mode) -ForegroundColor Cyan -NoNewline
  Write-Host ("  " + $SEP + "  " + $env:COMPUTERNAME + "  " + $SEP + "  " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
  $osShort = ($cv.ProductName -replace '^Windows( 1[01])? ','')
  Write-Host ("  " + $osShort + " " + $SEP + " " + $cv.CurrentBuild + "." + $cv.UBR + " " + $SEP + " CBS " + $cbs.Version) -ForegroundColor DarkGray
}
# The note is a plain line above the status; in interactive mode the status line carries the
# menu hint so it is always on screen.
function Verdict($word,$color,$note,$counts){
  Write-Host ""
  if ($note) { Write-Host ("  " + $note) -ForegroundColor Gray; Write-Host "" }
  Write-Host "  " -NoNewline
  Write-Host ($BLK + " ") -ForegroundColor $color -NoNewline
  Write-Host $word -ForegroundColor $color -NoNewline
  if ($counts) { Write-Host ("     " + $counts) -ForegroundColor DarkGray -NoNewline }
  if ($script:menu) { Write-Host "   " -NoNewline; MenuBits 'M=Menu|Q=Quit' }
  Write-Host ""
}
# Menu hints: 'M=Menu|Q=Quit' -> "[M] Menu   [Q] Quit" with the [key] in cyan, label in the
# regular console color. Write specs as "[X] Text". No trailing newline so it can end a
# verdict line.
function MenuBits($spec){
  $first = $true
  foreach ($item in ($spec -split '\|')) {
    $k,$label = $item -split '=',2
    if (-not $first) { Write-Host "   " -NoNewline }; $first = $false
    Write-Host ("[" + $k + "]") -ForegroundColor Cyan -NoNewline
    Write-Host (" " + $label) -NoNewline
  }
}
# One menu row, laid out like a report row: [key] in cyan, label in the same padded column
# the checks use, description dim.
function MenuRow($k,$label,$detail){
  Write-Host "  " -NoNewline
  Write-Host ("[" + $k + "]") -ForegroundColor Cyan -NoNewline
  Write-Host ("  " + ([string]$label).PadRight($LBLW) + "  ") -NoNewline
  Write-Host ([string]$detail) -ForegroundColor DarkGray
}

# ---- in-package call: run $Body (which emits output via W "...") under $AppId's identity,
#      deliver the script by -EncodedCommand and get its output back over a named pipe.
#      Returns the emitted lines, or $null on failure.
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
    $cv2 = Get-ItemProperty $c820[0].PSPath -ErrorAction SilentlyContinue
    $cStatus = $cv2.StatusCode; $cExpiry = $cv2.LastExpiration; $cUri = "$($cv2.RequestUri)"; $cRefresh = "$($cv2.RefreshTime)"
    if ($cExpiry) { try { $cExpired = ([DateTime]::Parse($cExpiry).ToUniversalTime() -lt [DateTime]::UtcNow) } catch {} }
    $cHasImg = ("$($cv2.RawJson)" -match 'landscapeImage|portraitImage|onecdn')
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

# UpdateTimer runs RefreshAllowed first and refuses to rotate within s_rotationPeriod (60 min,
# from DesktopSpotlight's own trace) of the last wallpaper touch (WallpaperRefresh) or last
# rotation (Rotation). A gated run still stamps UpdateTimer/State and re-registers the task
# set; it just does not rotate. This script never rewrites those stamps; it reports when the
# gate opens.
# Returns the UTC time the gate opens, or $null when it is open now.
function Get-GateOpens($s){
  $latest = $null
  foreach ($n in 'WallpaperRefresh','Rotation') {
    $v = $s.$n; if (-not $v) { continue }
    try { $t = [DateTime]::Parse($v).ToUniversalTime(); if (-not $latest -or $t -gt $latest) { $latest = $t } } catch {}
  }
  if ($latest -and ([DateTime]::UtcNow - $latest).TotalMinutes -lt 60) { return $latest.AddMinutes(60) }
  return $null
}

# ------------------------------------------------------------ in-package bodies ---
$EnumBody = @'
try { $ai=[Windows.ApplicationModel.AppInfo,Windows.ApplicationModel,ContentType=WindowsRuntime]::Current; W "AUMID=$($ai.AppUserModelId)" } catch { W "AUMID=?" }
$rt=[Windows.ApplicationModel.Background.BackgroundTaskRegistration,Windows.ApplicationModel,ContentType=WindowsRuntime]
foreach($kv in $rt::AllTasks){ W "TASK=$($kv.Value.Name)" }
try { W "ACCESS=$([Windows.ApplicationModel.Background.BackgroundExecutionManager,Windows.ApplicationModel,ContentType=WindowsRuntime]::GetAccessStatus())" } catch {}
'@

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

# Schedules a ONE-SHOT 15-minute TimeTrigger on the UpdateTimer entry point. Windows runs the
# real task itself within ~15-30 min (TimeTrigger's 15-min floor plus coarse alignment) and
# the one-shot registration removes itself afterwards. An ApplicationTrigger is accepted
# (RequestAsync -> Allowed) but never activates this timer-declared task - verified by ETW
# trace (0 DesktopSpotlight events on every attempt).
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

$UnschedBody = @'
$rt=[Windows.ApplicationModel.Background.BackgroundTaskRegistration,Windows.ApplicationModel,ContentType=WindowsRuntime]
$n=0
try { foreach($kv in $rt::AllTasks){ if($kv.Value.Name -eq 'DesktopSpotlight.BackgroundTask.UpdateTimer.fix15'){ $kv.Value.Unregister($false); $n++ } } } catch { W ("FAIL hr=0x{0:X8}" -f $_.Exception.HResult) }
W "REMOVED=$n"
'@

$PendingName = 'DesktopSpotlight.BackgroundTask.UpdateTimer.fix15'

# Read the registered tasks from inside the package. Right after a logon the broker can
# transiently surface 0 tasks to a fresh activation, so an empty first read is retried once.
function Read-Tasks {
  $enum = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $EnumBody -TimeoutSec 40
  if (-not $enum) { return $null }
  $aumid  = ($enum | Where-Object { $_ -like 'AUMID=*' }) -replace '^AUMID=',''
  $tasks  = @($enum | Where-Object { $_ -like 'TASK=*' } | ForEach-Object { $_ -replace '^TASK=','' })
  $access = ($enum | Where-Object { $_ -like 'ACCESS=*' }) -replace '^ACCESS=',''
  if ($tasks.Count -eq 0 -and $aumid -like "*!Global.DesktopSpotlight") {
    Start-Sleep -Seconds 20
    $enum = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $EnumBody -TimeoutSec 40
    $tasks  = @($enum | Where-Object { $_ -like 'TASK=*' } | ForEach-Object { $_ -replace '^TASK=','' })
    $access = ($enum | Where-Object { $_ -like 'ACCESS=*' }) -replace '^ACCESS=',''
  }
  [pscustomobject]@{ Aumid=$aumid; Tasks=$tasks; Access=$access; HasUpdateTimer=($tasks -contains 'DesktopSpotlight.BackgroundTask.UpdateTimer') }
}

# The recommendation in the health report's NEXT STEPS section: what to do next, and when,
# worked out from the same facts the report shows.
function NextStep($s0,$t){
  if ($s0.BackgroundType -ne 3) { return "Select Windows spotlight in Settings, then Fix" }
  $opens   = Get-GateOpens $s0
  $pending = ($t.Tasks -contains $PendingName)
  $needsFix = (-not $t.HasUpdateTimer) -or $s0.IsFallback
  $hhmm = if ($opens) { $opens.ToLocalTime().ToString('HH:mm') } else { '' }
  if ($needsFix) {
    if ($pending) { return "Wait - a fetch is already scheduled (15-30 min)" }
    if ($opens)   { return "Run Fix after $hhmm, when the gate opens" }
    return "Run Fix now - the gate is open"
  }
  if ($pending) { return "Nothing to do - fetch scheduled, photo in 15-30 min" }
  if ($t.Tasks -notcontains 'IrisService.BackgroundTask.NotificationHandler') {
    if ($opens) { return "Nothing to do - first run within 30 min, gate opens $hhmm" }
    return "Nothing to do - first run within 30 min, gate is open"
  }
  $next = $null; if ($s0.UpdateTimer) { try { $next = When ([DateTime]::Parse($s0.UpdateTimer).ToUniversalTime().AddHours(24).ToString('o')) } catch {} }
  if ($next) { return "Nothing to do - next photo expected $next" }
  return "Nothing to do - Spotlight is working"
}

# ------------------------------------------------------- health report (read-only) ---
function Show-Health($s0,$t){
  Banner 'health'
  $tasks = $t.Tasks

  Head 'critical'
  Chk 'CBS package'            'PASS' "$($cbs.Version) $SEP $($cbs.Status)"
  Chk 'Package identity'       $(if($t.Aumid -like '*!Global.DesktopSpotlight'){'PASS'}else{'FAIL'}) "$ELL!$($t.Aumid -replace '.*!','')"
  Chk 'UpdateTimer registered' $(if($t.HasUpdateTimer){'PASS'}else{'FAIL'}) $(if($t.HasUpdateTimer){'yes'}else{'MISSING - core failure'})
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
  # The script registers 7; NotificationHandler (a WNS push task) is not one of them. Spotlight's
  # own task manager registers it the first time UpdateTimer runs after a repair (~15-30 min,
  # gate or no gate - verified 2026-09-06 03:27 on a gated run). 7/8 with only that one missing
  # is the normal state right after a repair, not a fault.
  if ($missing.Count -eq 1 -and $missing[0] -eq 'IrisService.BackgroundTask.NotificationHandler') {
    Chk 'All 8 core tasks' 'NOTE' "7/8 $SEP NotificationHandler arrives on first run"
  } else {
    Chk 'All 8 core tasks' $(if($missing.Count){'WARN'}else{'PASS'}) $(if($missing.Count){"$(8-$missing.Count)/8 - missing $($missing -join ', ')"}else{'8/8'})
  }
  Chk 'Background exec access'  $(if($t.Access -match 'Allowed'){'PASS'}elseif($t.Access -match 'Denied'){'FAIL'}else{'WARN'}) $t.Access
  Chk 'Downloaded images'       $(if($s0.IrisFullSize -gt 0){'PASS'}else{'WARN'}) "$($s0.IrisFullSize) full-size ($($s0.IrisFiles) total)"
  Chk 'Wallpaper content cache' $(if($s0.Cache820 -and -not $s0.Cache820Expired -and $s0.Cache820HasImg){'PASS'}elseif($s0.Cache820){'WARN'}else{'WARN'}) $(if($s0.Cache820){"$($s0.Cache820Status) $SEP hasImages=$($s0.Cache820HasImg) $SEP $(if($s0.Cache820Expired){'EXPIRED'}else{'valid'})"}else{'no 88000820 entry'})
  Chk 'Last content retrieval'  $(if($s0.StateSuccess){'PASS'}else{'WARN'}) "success=$($s0.StateSuccess)$(if($s0.StateSuccessDate){'  '+$SEP+'  '+(When $s0.StateSuccessDate)+'  '+(Ago $s0.StateSuccessDate)})"
  $helpers = @($tasks | Where-Object { $_ -match '\.(fixapp2?|pwr|net|app|rotatetest)$' })
  Chk 'No leftover helpers'     $(if($helpers.Count){'WARN'}else{'PASS'}) $(if($helpers.Count){"$($helpers.Count) leftover: $($helpers -join ', ')"}else{'clean'})

  Head 'info'
  Chk 'Background mode'      'INFO' "$($s0.BackgroundType) $(if($s0.BackgroundType -eq 3){'(Windows spotlight)'}else{'(NOT spotlight)'})"
  Chk 'Images shown so far' 'INFO' "$($s0.ImagesUsed)  (~daily on content pull, not hourly)"
  Chk 'Last wallpaper change' 'INFO' $(if($s0.Rotation){"$(When $s0.Rotation)  $(Ago $s0.Rotation)"}else{'(never)'})
  # CBS re-registers UpdateTimer as a 1440-min TimeTrigger on every run, so the next run is
  # anchored to the last one (+24h; Windows aligns coarsely and catches up after sleep).
  # With no UpdateTimer registered there is no daily run and no download coming, whatever the
  # timestamps say - so these two lines say that instead of projecting from stale values.
  $needsFix = (-not $t.HasUpdateTimer) -or $s0.IsFallback
  # Right after a repair the script's own 15-min UpdateTimer is in place (NotificationHandler
  # still absent): the next run is that one, not +24h from a stale stamp.
  $fresh = $t.HasUpdateTimer -and ($tasks -notcontains 'IrisService.BackgroundTask.NotificationHandler')
  $nextRun = $null; if ($t.HasUpdateTimer -and $s0.UpdateTimer) { try { $nextRun = [DateTime]::Parse($s0.UpdateTimer).ToUniversalTime().AddHours(24) } catch {} }
  Chk 'Next daily run (expected)' 'INFO' $(if(-not $t.HasUpdateTimer){'none - UpdateTimer is not registered'}elseif($fresh){"within ~15-30 min (fresh repair), then daily"}elseif($nextRun){"$($nextRun.ToLocalTime().ToString('ddd HH:mm'))  $(Ago $nextRun.ToString('o'))  $SEP later if the PC was asleep"}else{'-'})
  Chk 'Next content download'    'INFO' $(if(-not $t.HasUpdateTimer){'none until the tasks are registered'}elseif($s0.Cache820Refresh){ $r=[DateTime]::Parse($s0.Cache820Refresh).ToUniversalTime(); "$($r.ToLocalTime().ToString('ddd HH:mm'))  $(Ago $r.ToString('o'))  $SEP same set until then" }else{'-'})
  $opens = Get-GateOpens $s0
  if ($opens) {
    # Amber whenever closed so it is seen; scored only when it is actually blocking a repair
    # (tasks missing or placeholder on screen). A healthy machine is gated for 60 min after
    # every rotation, and that is not a problem.
    Chk 'Refresh gate (60 min)' $(if($needsFix){'WARN'}else{'NOTE'}) ("closed " + $SEP + " opens " + $opens.ToLocalTime().ToString('HH:mm') + " " + $SEP + $(if($needsFix){" repair must wait until then"}else{" normal after a rotation"}))
  } else {
    Chk 'Refresh gate (60 min)' 'INFO' 'open'
  }
  Chk 'Content cache expires' 'INFO' $(if($s0.Cache820Expiry){"$(When $s0.Cache820Expiry)  $(Ago $s0.Cache820Expiry)"}else{'-'})
  if ($tasks -contains $PendingName) { Chk 'Fetch scheduled' 'INFO' 'one-shot timer pending (runs within ~15-30 min of scheduling, then removes itself)' }
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
  Verdict $vt $vc (NextStep $s0 $t) ("$($script:fails) fail " + $SEP + " $($script:warns) warn")
  return $(if($script:fails){2}elseif($script:warns){1}else{0})
}

# --------------------------------------------------------------------- repair ---
function Invoke-Repair($s0,$t,[bool]$ForceIt){
  Banner 'repair'

  Head 'state'
  Chk 'Background mode' $(if($s0.BackgroundType -eq 3){'PASS'}else{'WARN'}) $(if($s0.BackgroundType -eq 3){'3 (Windows spotlight)'}else{"$($s0.BackgroundType) - select Windows spotlight in Settings > Personalization > Background; the tasks only work while it is selected"})
  Chk 'Wallpaper' $(if($s0.IsFallback){'NOTE'}else{'PASS'}) $(if($s0.IsFallback){"placeholder $(Split-Path $s0.Wallpaper -Leaf) $SEP nothing fetched yet"}else{Split-Path $s0.Wallpaper -Leaf})
  Chk 'Last fetch' 'INFO' $(if($s0.UpdateTimer){"$(When $s0.UpdateTimer)  $(Ago $s0.UpdateTimer)"}else{'(never)'})

  Head 'tasks'
  Chk 'Package identity' 'PASS' "$ELL!$($t.Aumid -replace '.*!','')"
  Chk 'Background exec access' $(if($t.Access -match 'Allowed'){'PASS'}elseif($t.Access -match 'Denied'){'FAIL'}else{'WARN'}) $t.Access
  if ($t.HasUpdateTimer -and -not $ForceIt) {
    Chk 'UpdateTimer registered' 'PASS' 'yes'
    if (-not $s0.IsFallback) {
      Verdict 'NOTHING TO DO' 'Green' "registrations present and wallpaper is real"
      return 0
    }
    Chk 'Placeholder on screen' 'NOTE' 'tasks exist but never produced a photo - scheduling a fetch'
  } else {
    Chk 'UpdateTimer registered' $(if($t.HasUpdateTimer){'PASS'}else{'NOTE'}) $(if($t.HasUpdateTimer){'yes'}else{'missing - registering now'})
  }
  # Register whatever is missing, from inside each app's identity. Idempotent.
  foreach ($ctx in @(@{app='Global.DesktopSpotlight';which='DS';label='DesktopSpotlight tasks';n=4}, @{app='Global.IrisService';which='IRIS';label='IrisService tasks';n=3})) {
    $out = Invoke-InPackage -AppId $ctx.app -Body ($RegBodyTemplate.Replace('__WHICH__',$ctx.which)) -TimeoutSec 45
    if ($null -eq $out) { Chk $ctx.label 'FAIL' "no result from $($ctx.app)"; continue }
    $ok   = @($out | Where-Object { $_ -like 'OK=*' }   | ForEach-Object { ($_ -replace '^OK=','')   -replace '^.*\.BackgroundTask\.','' })
    $skip = @($out | Where-Object { $_ -like 'SKIP=*' })
    $bad  = @($out | Where-Object { $_ -like 'FAIL=*' } | ForEach-Object { $_ -replace '^FAIL=','' })
    if     ($bad.Count) { Chk $ctx.label 'FAIL' ($bad -join '; ') }
    elseif ($ok.Count)  { Chk $ctx.label 'PASS' ("registered " + ($ok -join ', ') + $(if($skip.Count){" $SEP $($skip.Count) already present"})) }
    else                { Chk $ctx.label 'PASS' "$($skip.Count)/$($ctx.n) already present" }
  }

  Head 'fetch'
  $opens = Get-GateOpens $s0
  if ($opens) {
    $wait = [int][Math]::Ceiling(($opens - [DateTime]::UtcNow).TotalMinutes)
    Chk 'Refresh gate (60 min)' 'FAIL' ("closed " + $SEP + " Windows ignores the timer until " + $opens.ToLocalTime().ToString('HH:mm') + " ($wait min)")
    Verdict 'BLOCKED' 'Yellow' ("tasks registered, nothing scheduled " + $SEP + " run again after " + $opens.ToLocalTime().ToString('HH:mm'))
    return 1
  }
  Chk 'Refresh gate (60 min)' 'PASS' 'open'
  $fire  = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $FireBody -TimeoutSec 60
  $sched = if ($fire) { (($fire | Where-Object { $_ -like 'SCHEDULED=*' }) -replace '^SCHEDULED=','') } else { 'FAIL (no result)' }
  if ($sched -like 'FAIL*') {
    Chk 'One-shot timer' 'FAIL' "could not register: $sched"
    Verdict 'FAILED' 'Red' 'the in-package registration failed'
    return 2
  }
  $t0 = Get-Date
  if ($sched -eq 'EXISTING') { Chk 'One-shot timer' 'PASS' "already pending from an earlier run $SEP leaving its clock alone" }
  else                       { Chk 'One-shot timer' 'PASS' ("registered " + $SEP + " id " + $sched.Substring(0,8) + $ELL + " " + $SEP + " removes itself after it runs") }
  if ($sched -eq 'EXISTING') { Chk 'Expected' 'INFO' ("within ~30 min of when it was scheduled " + $SEP + " locking, signing out or rebooting do not disturb it") }
  else { Chk 'Expected' 'INFO' (("Windows runs it between ~{0} and ~{1} " -f $t0.AddMinutes(15).ToString('HH:mm'), $t0.AddMinutes(30).ToString('HH:mm')) + $SEP + " locking, signing out or rebooting do not disturb it") }
  Chk 'Waiting' 'INFO' "up to 35 min $SEP Ctrl+C is safe, the timer stays scheduled"

  $before = $s0.Wallpaper; $deadline = $t0.AddMinutes(35); $s1 = $s0; $tick = Get-Date
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $s1 = Get-SpotlightState
    if ($s1.Wallpaper -ne $before -and -not $s1.IsFallback) { break }
    if (((Get-Date) - $tick).TotalSeconds -ge 60) { Chk (Get-Date).ToString('HH:mm') 'INFO' "still waiting $SEP wallpaper unchanged"; $tick = Get-Date }
  }
  if ($s1.Wallpaper -ne $before -and -not $s1.IsFallback) {
    $mins = [int][Math]::Round(((Get-Date) - $t0).TotalMinutes)
    Chk 'Wallpaper' 'PASS' ((Split-Path $s1.Wallpaper -Leaf) + "  $SEP new photo after $mins min")
    Chk 'Last fetch' 'PASS' "success=$($s1.StateSuccess)  $SEP  $($s1.IrisFullSize) full-size images on disk"
    Verdict 'FIXED' 'Green' ("new wallpaper set " + $SEP + " CBS keeps its own daily timer from here on")
    return 0
  }
  Chk 'Wallpaper' 'FAIL' "unchanged after 35 min"
  Verdict 'FAILED' 'Red' ("the timer did not rotate the wallpaper " + $SEP + " see the health report")
  return 2
}

# --------------------------------------------------------- remove pending fetch ---
function Remove-PendingFetch($t){
  Banner 'fetch'
  Head 'fetch'
  if ($t.Tasks -notcontains $PendingName) {
    Chk 'Pending one-shot' 'INFO' 'none pending'
    Verdict 'NOTHING PENDING' 'Green' 'no fetch was scheduled'
    return 0
  }
  $out = Invoke-InPackage -AppId 'Global.DesktopSpotlight' -Body $UnschedBody -TimeoutSec 40
  $n = if ($out) { (($out | Where-Object { $_ -like 'REMOVED=*' }) -replace '^REMOVED=','') } else { '' }
  if ($n -match '^\d+$' -and [int]$n -gt 0) {
    Chk 'Pending one-shot' 'PASS' "removed $SEP $PendingName"
    Verdict 'REMOVED' 'Green' 'the scheduled fetch will not run'
    return 0
  }
  Chk 'Pending one-shot' 'FAIL' "could not unregister $(($out | Where-Object { $_ -like 'FAIL*' }) -join ' ')"
  Verdict 'FAILED' 'Red' 'the in-package call did not succeed'
  return 2
}

# ------------------------------------------------------------------------ main ---
if ($PSVersionTable.PSEdition -ne 'Desktop') { Bad "Run this in Windows PowerShell 5.1 (powershell.exe), not pwsh - WinRT projection is required."; Bye 2; return }
$cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cbs = Get-AppxPackage -Name 'MicrosoftWindows.Client.CBS' -ErrorAction SilentlyContinue
if (-not $cbs) { Bad "MicrosoftWindows.Client.CBS is not registered for this user - this fix does not apply."; Bye 2; return }
if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) { Bad "Invoke-CommandInDesktopPackage (Appx module) not available."; Bye 2; return }

$s0 = Get-SpotlightState
$t  = Read-Tasks
if (-not $t) { Bad "Could not enumerate tasks inside the package."; Bye 2; return }
if ($t.Aumid -notlike "*!Global.DesktopSpotlight") { Bad "Package identity not acquired (AUMID='$($t.Aumid)')."; Bye 2; return }

$code = 0
if ($RemoveFetch) {
  $code = [int](Remove-PendingFetch $t | Select-Object -Last 1)
} elseif ($Fix -or $Force) {
  $code = [int](Invoke-Repair $s0 $t ([bool]$Force) | Select-Object -Last 1)
} else {
  # A bare run offers the menu; -HealthCheck is the same report without a prompt. The menu
  # is skipped whenever there is no console to read from (redirected input/output, ISE).
  $script:menu = (-not $HealthCheck) -and ($Host.Name -eq 'ConsoleHost') -and
                 -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
  if ($script:menu) { Clear-Host }   # interactive: each screen starts clean (never in unattended runs)
  $code = [int](Show-Health $s0 $t | Select-Object -Last 1)
  if ($script:menu) {
    # The report ends with "[M] menu". From then on: M opens the menu, an action runs and the
    # prompt comes back, Q leaves. Every action re-reads the machine first, so a
    # health check after a fix shows the new state.
    while ($true) {
      $key = $null
      try { $key = [Console]::ReadKey($true) } catch { break }
      if (-not $key) { break }
      $k = "$($key.KeyChar)".ToUpper()
      if ($k -eq 'Q') { break }
      if ($k -ne 'M') { continue }
      Clear-Host
      Banner 'menu'
      Head 'menu'
      MenuRow '1' 'Health check'         'read-only report, changes nothing'
      MenuRow '2' 'Fix'                  'register tasks, schedule a fetch, wait for the photo'
      MenuRow '3' 'Force'                'same, even if the tasks exist - no faster'
      MenuRow '4' 'Remove pending fetch' 'cancel a scheduled fetch'
      MenuRow 'Q' 'Quit'                 ''
      Write-Host ""
      $c = $null; try { $c = [Console]::ReadKey($true) } catch {}
      $choice = "$($c.KeyChar)".ToUpper()
      if ($choice -eq 'Q') { break }
      if ($choice -notin '1','2','3','4') { Write-Host "  " -NoNewline; MenuBits 'M=Menu|Q=Quit'; Write-Host ""; continue }
      Clear-Host
      $s0 = Get-SpotlightState
      $t  = Read-Tasks
      if (-not $t) { Bad "Could not enumerate tasks inside the package."; $code = 2; break }
      switch ($choice) {
        '1' { $code = [int](Show-Health $s0 $t                | Select-Object -Last 1) }
        '2' { $code = [int](Invoke-Repair $s0 $t $false       | Select-Object -Last 1) }
        '3' { $code = [int](Invoke-Repair $s0 $t $true        | Select-Object -Last 1) }
        '4' { $code = [int](Remove-PendingFetch $t            | Select-Object -Last 1) }
      }
    }
  }
}
Write-Host ""
Bye $code; return
