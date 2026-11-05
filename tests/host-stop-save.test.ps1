# Run: pwsh -NoProfile -File tests/host-stop-save.test.ps1 [-Script <host-instance.ps1>]  (Windows PowerShell 5.1 works too)
# Behaviour test of the self-host stop's save (Save-WorldBeforeKill in scripts/host-instance.ps1) with a fake clock,
# a fake save file and a fake host mod, so it runs in about a second and needs no game.
#
# A save request can land nothing, cause not known (the game's Save waits for a running save rather than
# refusing, read 2026-10-30). Lab pg1 2026-10-26: the game saved at 18:48:45.4, the Stop asked at
# 18:48:48, nothing new landed before the kill: "save before stop: NOT confirmed within 20 s".
# -Script <older host-instance.ps1> runs the same cases against another copy (the 10/26 one fails cases 2-4).
param([string]$Script = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'host-instance.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
$from = $src.IndexOf('$script:StopSaveTimings')
if ($from -lt 0) { $from = $src.IndexOf('function Save-WorldBeforeKill(') }
$to = $src.IndexOf('function Read-PidFile(')
if ($from -lt 0 -or $to -le $from) { throw 'Save-WorldBeforeKill not found in ' + $Script }
$code = $src.Substring($from, $to - $from)

$script:failures = 0; $script:checks = 0
function Check([bool]$cond, [string]$what, [string[]]$lines) {
  $script:checks++
  if ($cond) { Write-Output ('ok - ' + $what) } else { $script:failures++; Write-Output ('FAIL - ' + $what); $lines | ForEach-Object { Write-Output ('    ' + $_) } }
}

# --- fakes: clock, save file, marker, game process, host mod -------------------------------------------
$script:T0 = [datetime]::new(2026, 10, 28, 12, 0, 0, [DateTimeKind]::Local)
function Get-Date { $script:Now }
function Start-Sleep { param([int]$Milliseconds = 0, [int]$Seconds = 0) $script:Now = $script:Now.AddMilliseconds($Milliseconds + 1000 * $Seconds); Step-FakeHost }
function Join-Path { param([string]$Path, [string]$ChildPath) $Path.TrimEnd('\') + '\' + $ChildPath }  # fake paths on any OS
function L($m) { $script:Log += ('[' + ($script:Now - $script:T0).TotalSeconds.ToString('0.0') + '] ' + $m) }
function Test-HostHelperStalled { $false }
function Wait-GameOwnSave { $script:Log += 'Wait-GameOwnSave' }
function Get-Process {
  param([int]$Id = 0, $ErrorAction)
  if ($script:Now -ge $script:GameEndsAt) { return $null }
  [pscustomobject]@{ Id = $Id; ProcessName = 'BellwrightGame-Win64-Shipping' }
}
function Test-Path { param([string]$LiteralPath) if ($LiteralPath -eq $script:SavePath) { return ($null -ne $script:SaveAt) } ; return $false }
function Get-Item {
  param([string]$LiteralPath, $ErrorAction)
  if ($LiteralPath -ne $script:SavePath -or $null -eq $script:SaveAt) { return $null }
  [pscustomobject]@{ LastWriteTimeUtc = $script:SaveAt.ToUniversalTime(); Length = $script:SaveLen }
}
function Set-Content { param([string]$LiteralPath, $Value, $ErrorAction) if ($LiteralPath -eq $script:Marker) { $script:MarkerAt = $script:Now; $script:Requests += $script:Now } }
function Remove-Item { param([string]$LiteralPath, [switch]$Force, $ErrorAction) if ($LiteralPath -eq $script:Marker) { $script:MarkerAt = $null } }
# The host mod reads the marker within 2 s on the game thread and calls Save; the game writes the file 3 s later,
# unless it is still busy with its own save (BusyUntil) or the case says it refuses (RefuseCount requests refused).
function Step-FakeHost {
  if ($null -ne $script:Landing -and $script:Now -ge $script:Landing) { $script:SaveAt = $script:Landing; $script:SaveLen += 7; $script:Landing = $null }
  if ($null -ne $script:MarkerAt -and $script:Now -ge $script:MarkerAt.AddSeconds(1.5)) {
    $script:MarkerAt = $null # bw_host removes the marker once it has called Save
    $busy = ($script:Now -lt $script:BusyUntil)
    if ($busy -or $script:Refused -lt $script:RefuseCount) { $script:Refused++ } else { $script:Landing = $script:Now.AddSeconds(3) }
  }
}
function Run-Case([string]$name, [double]$ownSaveAgoS, [double]$busyForS, [int]$refuse, [double]$gameEndsAfterS = 1e6) {
  $script:Now = $script:T0; $script:Log = @(); $script:Requests = @(); $script:MarkerAt = $null; $script:Landing = $null
  $script:SavePath = 'Z:\fake\UserDir\Saved\SaveGames\TEMP_auto.sav'; $script:SaveLen = 4400000
  $script:SaveAt = $script:T0.AddSeconds(-$ownSaveAgoS)
  $script:BusyUntil = $script:SaveAt.AddSeconds($busyForS)
  $script:RefuseCount = $refuse; $script:Refused = 0
  $script:GameEndsAt = $script:T0.AddSeconds($gameEndsAfterS)
  $script:logDir = 'Z:\fake\Logs'; $script:Marker = 'Z:\fake\Logs\hearth_force_save_8377.marker'
  Save-WorldBeforeKill 4242 8377 $script:SavePath
  [pscustomobject]@{ Log = $script:Log; Requests = $script:Requests; Took = ($script:Now - $script:T0).TotalSeconds; Marker = $script:MarkerAt }
}

. ([scriptblock]::Create($code))
$logDir = 'Z:\fake\Logs'

# 1. nothing recent: one request, the game saves, "confirmed"
$r = Run-Case 'plain' 100 0 0
Check (($r.Log -join "`n") -match 'save before stop: confirmed$' -and $r.Requests.Count -eq 1) 'no recent own save: one request, confirmed' $r.Log
# 2. the lab case: the game saved 0.6 s before the Stop and stays busy 5 s; the request waits for it and is taken
$r = Run-Case 'lab' 0.6 5 0
$firstAfter = if ($r.Requests.Count) { ($r.Requests[0] - $script:T0.AddSeconds(-0.6)).TotalSeconds } else { -1 }
Check (($r.Log -join "`n") -match 'save before stop: confirmed$' -and $firstAfter -ge 8) 'own save 0.6 s before: waits until it has finished (request 8+ s after it), then confirmed' $r.Log
# 3. the game refuses the first request (still busy for 25 s): asked once more, confirmed
$r = Run-Case 'retry' 1 25 0
Check (($r.Log -join "`n") -match 'confirmed \(asked again after the game''s own save\)' -and $r.Requests.Count -eq 2) 'first request refused while the game is busy: asked once more and confirmed' $r.Log
# 4. no request lands: its own save of 2 s before the Stop is the world we keep
$r = Run-Case 'refuse' 2 0 9
Check (($r.Log -join "`n") -match 'confirmed \(game autosave 2 s before the stop\)' -and $r.Requests.Count -eq 2 -and $r.Took -le 50) 'every request refused after a save 2 s before: confirmed (game autosave), two requests, within 50 s' $r.Log
# 5. nothing recent and the game never saves: not confirmed after 20 s, one request only
$r = Run-Case 'none' 100 0 9
Check (($r.Log -join "`n") -match 'NOT confirmed within 20 s' -and $r.Requests.Count -eq 1 -and $r.Took -le 21) 'no recent own save and no save: NOT confirmed after 20 s, one request' $r.Log
# 6. the game ends while we wait: no hang, no second request
$r = Run-Case 'gameends' 1 25 0 4
Check ($r.Took -le 6 -and $r.Requests.Count -le 1) 'the game ends during the wait: the stop goes on at once' $r.Log
# 7. the marker never outlives the stop
Check ($null -eq $r.Marker) 'the marker is gone when the stop goes on' @()

Write-Output ('{0} of {1} stop-save checks passed' -f ($script:checks - $script:failures), $script:checks)
exit ([int]($script:failures -ne 0))
