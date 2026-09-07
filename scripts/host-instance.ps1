#requires -Version 5.1
<#
.SYNOPSIS
  Run one Bellwright server with Hearth: stage UE4SS + bw_host beside the game,
  launch Bellwright headless, apply the build-locked native patches, wait for the
  gameplay port to bind, then supervise (relaunch on crash, recycle on request).

.DESCRIPTION
  This is the host launch path. It is the same sequence a managed Hearth host
  runs, packaged so anyone with a Windows box and a copy of Bellwright can host.

  Layout it expects (the release package extracts to exactly this):

    <PackageRoot>\HearthServer\HearthServer.exe    the supervisor (RCON, A2S query, admin API)
    <PackageRoot>\HearthServer\HearthSaveGuard.exe save protection helper
    <PackageRoot>\HearthServer\appsettings.json    YOUR settings (ports, name, RCON password, admins)
    <PackageRoot>\ue4ss\UE4SS.dll                  UE4SS runtime + settings + signatures + Mods\bw_host
    <PackageRoot>\redist\d3d10warp.dll             dormant WARP fallback (not used under -nullrhi)
    <PackageRoot>\host-instance.ps1                this script

  What it does, in order:
    1. Reads HearthServer\appsettings.json (GameplayPort, MaxPlayers, AdminSteamIds,
       WorldName, GameUserDir) so there is one place to configure the server.
    2. Reaps stuck CrashReportClient / WerFault processes (they wedge relaunches).
    3. Stages the UE4SS runtime into <game>\Bellwright\Binaries\Win64\ue4ss\.
    4. Re-emits the per-instance Engine.ini (listen port + net tuning) under the
       UserDir. Unreal rewrites this file on a clean exit, so it is re-emitted
       on every launch.
    5. Starts HearthServer.exe and keeps it alive for the host's whole life.
    6. Launches BellwrightGame-Win64-Shipping.exe with -nullrhi (no GPU needed),
       injects UE4SS ~400 ms into engine init, applies the native crash/fog
       patches for the pinned build, and waits for the gameplay UDP port.
    7. Supervises: relaunches on crash, recycles on a restart request, exits
       cleanly on a stop request.

  Stop / restart from another shell:
    .\host-instance.ps1 -Stop
    .\host-instance.ps1 -Restart

.PARAMETER GameRoot
  REQUIRED. The Bellwright install to host from (the folder that contains
  Bellwright\Binaries\Win64\BellwrightGame-Win64-Shipping.exe). Install it with
  SteamCMD using a Steam account that owns Bellwright (app 1812450), or copy your
  Steam library folder. The game files are never modified.

.PARAMETER PackageRoot
  Where the Hearth host package was extracted. Default: this script's folder.

.PARAMETER CoresPerInstance
  CPU cores to pin the game to. Default 0 = do not pin (use the whole box). Set
  it when running several instances on one machine; each instance then gets a
  disjoint tile keyed off its gameplay port (base 7777, stride 100).

.PARAMETER Stop
  Ask a running instance to stop (writes the stop marker, ends the supervisor and
  the game process), then exit.

.PARAMETER Restart
  Ask a running instance to recycle its game process (the supervisor and
  HearthServer stay up), then exit.

.EXAMPLE
  .\host-instance.ps1 -GameRoot "D:\Bellwright"

.NOTES
  Bellwright is D3D12-only and cannot run on D3D11. Under -nullrhi there is no
  render pipeline at all, so no GPU is needed. The WARP flags and redist are kept
  as dormant fallback machinery.

  Firewall: the gameplay port (UDP), query port (UDP), RCON port (TCP) and HTTP
  port (TCP) need inbound allow rules. The script adds them with netsh when it
  runs elevated; otherwise add them yourself.
#>
[CmdletBinding()]
param(
  [string]$GameRoot = '',
  [string]$PackageRoot = '',
  [int]$CoresPerInstance = 0,
  [switch]$Stop,
  [switch]$Restart
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$serverDir   = Join-Path $PackageRoot 'HearthServer'
$serverExe   = Join-Path $serverDir 'HearthServer.exe'
$settingsPath = Join-Path $serverDir 'appsettings.json'
$logDir      = Join-Path $PackageRoot 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logPath     = Join-Path $logDir 'host.log'
$pidFile     = Join-Path $logDir 'bw.pid'
$supPidFile  = Join-Path $logDir 'bw_supervisor.pid'
$serverPidFile = Join-Path $logDir 'hearthserver.pid'
$restartReq  = Join-Path $logDir 'bw_restart.request'
$stopMarker  = Join-Path $logDir 'bw_stop.marker'
function L($m){ $line = ('[' + (Get-Date -Format o) + '] ' + $m); Write-Host $line; Add-Content -LiteralPath $logPath -Value $line -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# -Stop / -Restart: signal a running instance and leave.
# ---------------------------------------------------------------------------
if ($Stop) {
  [IO.File]::WriteAllText($stopMarker, 'stop', [System.Text.Encoding]::ASCII)
  foreach ($pf in @($supPidFile, $pidFile, $serverPidFile)) {
    if (Test-Path -LiteralPath $pf) {
      $p = 0; try { $p = [int](Get-Content -LiteralPath $pf -ErrorAction Stop | Select-Object -First 1) } catch {}
      if ($p -gt 0) { try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {} }
      Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    }
  }
  L 'stop requested: supervisor, game and HearthServer signalled'
  return
}
if ($Restart) {
  [IO.File]::WriteAllText($restartReq, 'restart', [System.Text.Encoding]::ASCII)
  L 'restart requested: the supervisor will recycle the game process within 15 s'
  return
}

# ---------------------------------------------------------------------------
# Inputs: appsettings.json is the single place to configure the server.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $serverExe)) { throw "HearthServer.exe not found at $serverExe (extract the host package first)" }
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "appsettings.json not found at $settingsPath" }
$settings = $null
try { $settings = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json) } catch { throw "appsettings.json is not valid JSON: $($_.Exception.Message)" }
$hearth = $settings.Hearth
if (-not $hearth) { throw 'appsettings.json has no "Hearth" section' }
# This script owns the game process. HearthServer.exe has its own in-process
# launcher that wakes up when GameInstallRoot / GameExecutablePath are set, and two
# launchers on one install would fight, so those must stay empty here.
if (-not [string]::IsNullOrWhiteSpace([string]$hearth.GameInstallRoot) -or -not [string]::IsNullOrWhiteSpace([string]$hearth.GameExecutablePath)) {
  throw 'Leave Hearth.GameInstallRoot and Hearth.GameExecutablePath empty in appsettings.json and pass -GameRoot to this script instead'
}
if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'Pass -GameRoot <Bellwright install folder>' }
$GameRoot = (Resolve-Path -LiteralPath $GameRoot).Path
$gameBinDir = $null
foreach ($cand in @((Join-Path $GameRoot 'Bellwright\Binaries\Win64'), (Join-Path $GameRoot 'Mist\Binaries\Win64'), (Join-Path $GameRoot 'Binaries\Win64'), $GameRoot)) {
  if (Test-Path -LiteralPath (Join-Path $cand 'BellwrightGame-Win64-Shipping.exe')) { $gameBinDir = $cand; break }
}
if (-not $gameBinDir) { throw "BellwrightGame-Win64-Shipping.exe not found under $GameRoot" }
$spExePath = Join-Path $gameBinDir 'BellwrightGame-Win64-Shipping.exe'
$workDir   = $gameBinDir

$gameplayPort = [int]$hearth.GameplayPort; if ($gameplayPort -le 0) { $gameplayPort = 7777 }
$queryPort = [int]$hearth.QueryPort; if ($queryPort -le 0) { $queryPort = $gameplayPort + 2 }
$rconPort  = [int]$hearth.RconPort;  if ($rconPort -le 0)  { $rconPort  = $gameplayPort + 3 }
$httpPort  = [int]$hearth.HttpPort;  if ($httpPort -le 0)  { $httpPort  = $gameplayPort + 4 }
$maxPlayers = [int]$hearth.MaxPlayers; if ($maxPlayers -lt 1) { $maxPlayers = 4 }; if ($maxPlayers -gt 64) { $maxPlayers = 64 }
$adminIds = ''
if ($hearth.AdminSteamIds) { $adminIds = (@($hearth.AdminSteamIds) | ForEach-Object { [string]$_ }) -join ',' }
$userDir = [string]$hearth.GameUserDir
if ([string]::IsNullOrWhiteSpace($userDir)) { $userDir = Join-Path $PackageRoot 'UserDir' }
if (-not [IO.Path]::IsPathRooted($userDir)) { $userDir = Join-Path $serverDir $userDir }
if (-not (Test-Path -LiteralPath $userDir)) { New-Item -ItemType Directory -Force -Path $userDir | Out-Null }
$userDir = (Resolve-Path -LiteralPath $userDir).Path
# The vanilla install must never be used as the UserDir: Engine.ini and the
# save-dir writes would land inside the game folder.
if ($userDir.StartsWith($GameRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "GameUserDir ($userDir) must not be inside the Bellwright install ($GameRoot)" }
# World map bw_host opens. The short name / NewGameMapName fallback resolves to the
# empty Entry boot map on current builds, so the full package path is the default.
$saveDir = [string]$hearth.SaveDir
if ([string]::IsNullOrWhiteSpace($saveDir)) { $saveDir = Join-Path $PackageRoot 'Saves' }
if (-not [IO.Path]::IsPathRooted($saveDir)) { $saveDir = Join-Path $serverDir $saveDir }
if (-not (Test-Path -LiteralPath $saveDir)) { New-Item -ItemType Directory -Force -Path $saveDir | Out-Null }
$hearthWorldName = [string]$hearth.WorldName
if ([string]::IsNullOrWhiteSpace($hearthWorldName)) { $hearthWorldName = '/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08' }

$packageUe4ss = Join-Path $PackageRoot 'ue4ss'
$targetUe4ss  = Join-Path $gameBinDir 'ue4ss'
$ue4ssDll     = Join-Path $targetUe4ss 'UE4SS.dll'
$ue4ssLog     = Join-Path $targetUe4ss 'UE4SS.log'
$pluginDll    = Join-Path $packageUe4ss 'HearthPlugin.dll'
$hostLog      = Join-Path $logDir 'bw_host.log'
$ueLog        = Join-Path $userDir 'bw-ue.log'
$fogPatchMarker = Join-Path $logDir 'map-fog-native-ready'
$fogActorEnabled = $true
$warpDll      = Join-Path $PackageRoot 'redist\d3d10warp.dll'
$xefgDir      = Join-Path $GameRoot 'Bellwright\Plugins\XeSS\Binaries\ThirdParty\Win64'
$serverLog    = Join-Path $logDir 'hearthserver.log'
$saveGuardPath = Join-Path $serverDir 'HearthSaveGuard.exe'
$canonicalSave = Join-Path $userDir 'Saved\SaveGames\TEMP_auto.sav'
$playerLedger  = Join-Path $serverDir 'data\player-records'
$gameplaySettingsFile   = Join-Path $serverDir 'data\gameplay-settings.cfg'
$gameplaySettingsStatus = Join-Path $logDir 'gameplay-settings.status'
$adminTicketFile = [string]$hearth.AdminJoinTicketPath
if ([string]::IsNullOrWhiteSpace($adminTicketFile)) { $adminTicketFile = 'data\admin-join-tickets.tsv' }
if (-not [IO.Path]::IsPathRooted($adminTicketFile)) { $adminTicketFile = Join-Path $serverDir $adminTicketFile }
if (-not (Test-Path -LiteralPath (Join-Path $serverDir 'data'))) { New-Item -ItemType Directory -Force -Path (Join-Path $serverDir 'data') | Out-Null }

$K = [int]$CoresPerInstance
$basePort = 7777; $portStride = 100
$portOffset = $gameplayPort - $basePort
$slot = 0
if ($portOffset -ge 0) { $slot = [int][math]::Floor($portOffset / $portStride) }

if (-not (Test-Path -LiteralPath $logPath)) { New-Item -ItemType File -Force -Path $logPath | Out-Null }
L ('Starting Bellwright host: game=' + $spExePath + ' package=' + $PackageRoot + ' userdir=' + $userDir)
L ('  gameplay=' + $gameplayPort + ' query=' + $queryPort + ' rcon=' + $rconPort + ' http=' + $httpPort + ' maxPlayers=' + $maxPlayers + ' world=' + $hearthWorldName)

# ---------------------------------------------------------------------------
# Gameplay settings. Edit HearthServer\data\gameplay-settings.cfg (a template is
# written on first run). The host mod only applies a file whose revision line is
# the sha256 of the canonical payload, so it is recomputed here on every launch.
# ---------------------------------------------------------------------------
$gameplayKeys = @('raids_enabled','raids_on_outposts','raid_frequency','raid_strength','brigands_raid_frequency',
  'brigands_raid_strength','bandits_migration_frequency','multiple_threats','weapon_requirements','armor_requirements',
  'food_spoilage_speed','hunger_speed','equipment_breaking_speed','skills_learning_speed','melee_damage','ranged_damage',
  'village_needs','village_needs_prosperity_reward','village_needs_prosperity_penalty','fishing_difficulty','show_dialogue_choice_effects')
$gameplayDefaults = @{ raids_enabled='1'; raids_on_outposts='1'; raid_frequency='1'; raid_strength='1'; brigands_raid_frequency='1';
  brigands_raid_strength='1'; bandits_migration_frequency='2'; multiple_threats='0'; weapon_requirements='1'; armor_requirements='1';
  food_spoilage_speed='1.00'; hunger_speed='1.00'; equipment_breaking_speed='1.00'; skills_learning_speed='1.00'; melee_damage='1.00';
  ranged_damage='1.00'; village_needs='1.00'; village_needs_prosperity_reward='1.00'; village_needs_prosperity_penalty='1.00';
  fishing_difficulty='1'; show_dialogue_choice_effects='1' }
function Update-GameplaySettings {
  $values = @{}
  $managed = '0'
  if (Test-Path -LiteralPath $gameplaySettingsFile) {
    foreach ($line in (Get-Content -LiteralPath $gameplaySettingsFile -ErrorAction SilentlyContinue)) {
      $line = [string]$line; if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
      $i = $line.IndexOf('='); if ($i -le 0) { continue }
      $k = $line.Substring(0, $i).Trim(); $v = $line.Substring($i + 1).Trim()
      if ($k -eq 'managed') { $managed = $v } elseif ($gameplayKeys -contains $k) { $values[$k] = $v }
    }
  } else {
    $tpl = @("# Hearth gameplay settings. Set managed=1 to have the server enforce these values;", "# managed=0 leaves the world's own settings alone. The revision line is rewritten on launch.", "managed=0")
    foreach ($k in $gameplayKeys) { $tpl += ($k + '=' + $gameplayDefaults[$k]) }
    [IO.File]::WriteAllText($gameplaySettingsFile, (($tpl -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    L ('wrote gameplay settings template ' + $gameplaySettingsFile + ' (managed=0)')
    return $false
  }
  if ($managed -ne '1') { L 'gameplay settings: managed=0 (world settings untouched)'; return $false }
  $payload = "managed=1`n"
  foreach ($k in $gameplayKeys) {
    $v = $values[$k]; if ($null -eq $v -or $v -eq '') { $v = $gameplayDefaults[$k] }
    if ($gameplayDefaults[$k] -match '\.') { $v = ([double]$v).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) } else { $v = [string][int]$v }
    $values[$k] = $v
    $payload += ($k + '=' + $v + "`n")
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join ''
  $out = 'revision=' + $hash + "`r`n" + ($payload -replace "`n", "`r`n")
  [IO.File]::WriteAllText($gameplaySettingsFile, $out, [System.Text.Encoding]::ASCII)
  L ('gameplay settings: managed=1 revision=' + $hash)
  return $true
}
$gameplayManaged = Update-GameplaySettings

# ---------------------------------------------------------------------------
# Firewall (best effort, needs elevation). Defender silently drops inbound UDP on
# the gameplay port without an allow rule, so the socket looks bound and nobody
# can join.
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
  foreach ($rule in @(@('UDP', $gameplayPort), @('UDP', $queryPort), @('TCP', $rconPort), @('TCP', $httpPort))) {
    $name = 'Hearth Bellwright ' + $rule[0] + ' ' + $rule[1]
    $exists = (netsh advfirewall firewall show rule name="$name" 2>$null | Select-String -SimpleMatch 'Rule Name' -Quiet)
    if (-not $exists) { netsh advfirewall firewall add rule name="$name" dir=in action=allow protocol=$($rule[0]) localport=$($rule[1]) | Out-Null; L ('firewall: added inbound ' + $rule[0] + ' ' + $rule[1]) }
  }
} else {
  L ('firewall: not elevated, skipping rule check. Allow inbound UDP ' + $gameplayPort + ', UDP ' + $queryPort + ', TCP ' + $rconPort + ', TCP ' + $httpPort + ' yourself.')
}

# STEP 1: reap stuck crash dialogs (a stuck CrashReportClient*/WerFault blocks all
# subsequent UE launches on the box).
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'CrashReportClient*' -or $_.ProcessName -eq 'WerFault' -or $_.ProcessName -eq 'WerFaultSecure' } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

# STEP 2: stage the UE4SS runtime into Binaries\Win64\ue4ss\ (UE4SS.dll + settings +
# the 5 PDB signatures + Mods). UE4SS is loaded post-boot by the CreateRemoteThread +
# LoadLibraryW injector below, NOT by a dwmapi.dll proxy (the proxy maps the DLL but
# does not reliably init UE4SS on this build). UE4SS resolves its settings, signatures
# and mods relative to its own staged location.
if (-not (Test-Path -LiteralPath (Join-Path $packageUe4ss 'UE4SS.dll'))) { throw "UE4SS.dll missing from $packageUe4ss (incomplete package)" }
if (-not (Test-Path -LiteralPath (Join-Path $packageUe4ss 'Mods\bw_host\Scripts\main.lua'))) { throw "bw_host missing from $packageUe4ss\Mods (incomplete package)" }
if (-not (Test-Path -LiteralPath (Join-Path $packageUe4ss 'UE4SS_Signatures'))) { throw "UE4SS_Signatures missing from $packageUe4ss (incomplete package)" }
if (-not (Test-Path -LiteralPath $targetUe4ss)) { New-Item -ItemType Directory -Force -Path $targetUe4ss | Out-Null }
Copy-Item -Force -LiteralPath (Join-Path $packageUe4ss 'UE4SS.dll') -Destination $ue4ssDll
Copy-Item -Force -LiteralPath (Join-Path $packageUe4ss 'UE4SS-settings.ini') -Destination (Join-Path $targetUe4ss 'UE4SS-settings.ini')
robocopy (Join-Path $packageUe4ss 'UE4SS_Signatures') (Join-Path $targetUe4ss 'UE4SS_Signatures') /MIR /NFL /NDL /NJH /NJS /NC /NS /NP /R:1 /W:1 | Out-Null
robocopy (Join-Path $packageUe4ss 'Mods') (Join-Path $targetUe4ss 'Mods') /MIR /NFL /NDL /NJH /NJS /NC /NS /NP /R:1 /W:1 | Out-Null
# A stale dwmapi.dll proxy beside the exe would half-load UE4SS and fight the inject.
Remove-Item -Force -LiteralPath (Join-Path $gameBinDir 'dwmapi.dll') -ErrorAction SilentlyContinue
L ('staged UE4SS runtime into ' + $targetUe4ss)

# STEP 3: the per-instance Engine.ini. Bellwright sets its Steam net driver in native
# code and ignores config NetDriverDefinitions; bw_host swaps the driver in memory at
# runtime. This file only pins the listen port, the net tuning and the headless
# quality floor. Unreal wipes it at shutdown, so it is re-emitted every launch.
$engineIni = @"
; Hearth-managed Engine.ini - re-emitted on every host launch.

[URL]
Port=$gameplayPort

[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=60
NetConnectionClassName=/Script/OnlineSubsystemUtils.IpConnection
ConnectionTimeout=600.0
InitialConnectTimeout=600.0
; High-bandwidth open-world join. The effective per-connection cap is the
; minimum of IpNetDriver rate, client ConfiguredInternetSpeed, and
; GameNetworkManager MaxDynamicBandwidth, so raise them together.
MaxClientRate=2097152
MaxInternetClientRate=2097152
ServerDesiredSocketReceiveBufferBytes=4194304
ServerDesiredSocketSendBufferBytes=4194304
ClientDesiredSocketReceiveBufferBytes=2097152
ClientDesiredSocketSendBufferBytes=2097152

[/Script/Engine.Player]
ConfiguredInternetSpeed=2097152
ConfiguredLanSpeed=2097152

[/Script/Engine.GameNetworkManager]
TotalNetBandwidth=16777216
MaxDynamicBandwidth=2097152
MinDynamicBandwidth=524288

[/Script/Engine.Engine]
bUseFixedFrameRate=true
FixedFrameRate=30.000000

[ConsoleVariables]
t.MaxFPS=30
sg.GlobalIlluminationQuality=0
sg.ReflectionQuality=0
sg.ShadowQuality=0
sg.PostProcessQuality=0
sg.TextureQuality=0
sg.EffectsQuality=0
sg.FoliageQuality=0
net.UseAdaptiveNetUpdateFrequency=1
net.TrackQueuedActorThreshold=1
net.TrackQueuedActorThresholdOwner=1
"@ -replace "`r?`n", "`r`n"
foreach ($cfgDir in @((Join-Path $userDir 'Saved\Config\Windows'), (Join-Path $userDir 'Bellwright\Saved\Config\Windows'), (Join-Path $userDir 'Bellwright\Saved\Config\WindowsServer'))) {
  if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
  [IO.File]::WriteAllText((Join-Path $cfgDir 'Engine.ini'), $engineIni, [System.Text.Encoding]::ASCII)
}
L ('emitted Engine.ini (Port=' + $gameplayPort + ') under ' + $userDir)

# Launch args. -nullrhi: no render pipeline, so the host ticks at the full frame cap
# with no GPU. The WARP-era dpcvars and the low-render floor are kept as dormant
# fallback machinery. -UserDir scopes Saved\ per instance; -port pairs with the
# [URL] Port pin.
$lowRenderCvars = 't.MaxFPS=8,r.ScreenPercentage=6,r.SkyAtmosphere=0,r.VolumetricFog=0,r.VolumetricCloud=0,r.Fog=0,r.Lumen.DiffuseIndirect.Allow=0,r.RayTracing=0,r.Shadow.Virtual.Enable=0,r.ShadowQuality=0,r.HZBOcclusion=0,r.ViewDistanceScale=0.1,r.DetailMode=0,r.SkeletalMeshLODBias=4,r.Streaming.PoolSize=200,r.MipMapLODBias=4,r.DefaultFeature.MotionBlur=0,r.DefaultFeature.Bloom=0,r.DefaultFeature.AmbientOcclusion=0,mutable.EnableSkeletalMeshUpdate=0,mutable.SkipResourceGenerationOnConstruction=1,mutable.MaxTextureSizeToGenerate=64,mutable.EnableMutableLiveUpdateMode=0'
$spArgs = '-nullrhi -nosound -unattended -nosplash -log' +
  ' -dpcvars="r.XeFG.OverrideSwapChain=0,r.XeFG.Enabled=0,r.XeFG.Supported=0,r.XeSS.Enabled=0,r.Streamline.DLSSG.Enable=0,r.NGX.DLSS.Enable=0,r.Streamline.MaxNumSwapchainProxies=0,' + $lowRenderCvars + '"' +
  ' -abslog="' + $ueLog + '"' +
  ' -LogCmds="LogNet Verbose,LogOnline Verbose,LogLoad Verbose,LogExit Verbose"' +
  ' -UserDir="' + $userDir + '" -port=' + $gameplayPort

# Environment bw_host reads (inherited by the game process). The temp files are the
# spawn-method-agnostic fallback the mod also checks.
$env:HEARTH_WORLD_NAME = $hearthWorldName
try { [IO.File]::WriteAllText('C:\Windows\Temp\hearth_world_name.txt', $hearthWorldName, [System.Text.Encoding]::ASCII) } catch {}
$env:HEARTH_GAME_PORT = [string]$gameplayPort
try { [IO.File]::WriteAllText('C:\Windows\Temp\hearth_game_port.txt', [string]$gameplayPort, [System.Text.Encoding]::ASCII) } catch {}
$env:HEARTH_MAX_PLAYERS = [string]$maxPlayers
try { [IO.File]::WriteAllText('C:\Windows\Temp\hearth_max_players.txt', [string]$maxPlayers, [System.Text.Encoding]::ASCII) } catch {}
$env:HEARTH_ADMIN_STEAM_IDS = $adminIds
$env:HEARTH_ADMIN_TICKET_FILE = $adminTicketFile
$env:HEARTH_SAVE_FILE = $canonicalSave
if ($gameplayManaged) {
  $env:HEARTH_GAMEPLAY_SETTINGS_FILE = $gameplaySettingsFile
  $env:HEARTH_GAMEPLAY_SETTINGS_STATUS = $gameplaySettingsStatus
} else {
  Remove-Item Env:HEARTH_GAMEPLAY_SETTINGS_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:HEARTH_GAMEPLAY_SETTINGS_STATUS -ErrorAction SilentlyContinue
}

# HearthServer = the A2S/query/RCON responder + admin API. It must stay up for the
# host's whole life or clients see the server Offline. Launched here and relaunched
# by the supervisor loop whenever it exits.
# The supervisor reads the same paths this script derived. Hand them over as
# configuration overrides so a relative or empty appsettings entry cannot point it
# somewhere else (the .NET host reads Hearth__<Key> from the environment).
$env:Hearth__GameUserDir = $userDir
$env:Hearth__GamePidFile = $pidFile
$env:Hearth__SaveDir = $saveDir
$env:Hearth__AdminJoinTicketPath = $adminTicketFile
function Start-Hearthserver {
  try {
    $p = Start-Process -FilePath $serverExe -WorkingDirectory $serverDir `
      -RedirectStandardOutput $serverLog -RedirectStandardError ($serverLog + '.err') `
      -PassThru -WindowStyle Hidden -ErrorAction Stop
    if ($p) { try { $p.Id | Set-Content -Encoding ASCII $serverPidFile } catch {}; L ('HearthServer started pid=' + $p.Id + ' (A2S/query responder)'); return $p }
  } catch { L ('HearthServer start FAILED: ' + $_.Exception.Message) }
  return $null
}
function Test-HearthserverAlive([System.Diagnostics.Process]$p) {
  if (-not $p) { return $false }
  try { $live = Get-Process -Id $p.Id -ErrorAction SilentlyContinue } catch { return $false }
  if (-not $live) { return $false }
  return ($live.ProcessName -like 'HearthServer*')
}
function Protect-Save {
  if (-not (Test-Path -LiteralPath $saveGuardPath)) { L 'save protection FAILED: helper missing'; return $false }
  $target = $canonicalSave
  if (-not (Test-Path -LiteralPath $target)) {
    $legacy = Join-Path (Split-Path -Parent $canonicalSave) 'savegame_0.sav'
    if (Test-Path -LiteralPath $legacy) { $target = $legacy } else { return $true }
  }
  try {
    $guardOutput = (& $saveGuardPath protect --save $target --ledger $playerLedger 2>&1 | Out-String).Trim()
    $guardExit = $LASTEXITCODE
    if ($guardExit -ne 0) { L ('save protection FAILED: ' + $guardOutput); return $false }
    L ('save protection: ' + $guardOutput)
    return $true
  } catch { L ('save protection FAILED: ' + $_.Exception.Message); return $false }
}
try { Set-Content -LiteralPath (Join-Path $gameBinDir 'steam_appid.txt') -Value '1812450' -Encoding ASCII -NoNewline -ErrorAction SilentlyContinue } catch {}
# WARP redist (dormant under -nullrhi): staged beside the exe so the fallback render
# path has a UE5-capable rasterizer if it is ever needed.
if (Test-Path -LiteralPath $warpDll) { try { Copy-Item -Force -LiteralPath $warpDll -Destination (Join-Path $workDir 'd3d10warp.dll') -ErrorAction SilentlyContinue } catch {} }
# DirectX Agility runtime: Bellwright's Steam files place these in D3D12\x64, but UE's
# app-local loader looks in D3D12 relative to the exe. Copy, don't move.
$d3d12Dir = Join-Path $workDir 'D3D12'
$d3d12X64Dir = Join-Path $d3d12Dir 'x64'
foreach ($dx in @('D3D12Core.dll','d3d12SDKLayers.dll')) {
  $src = Join-Path $d3d12X64Dir $dx
  $dst = Join-Path $d3d12Dir $dx
  if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
    try { Copy-Item -Force -LiteralPath $src -Destination $dst -ErrorAction Stop } catch { L ('DirectX Agility stage failed for ' + $dx + ': ' + $_.Exception.Message) }
  }
}
# XeFG (Intel frame-gen) crashes a no-GPU host at first viewport draw. Neutralize the
# frame-gen redist DLLs so the custom DXGI swapchain provider cannot register.
# Idempotent (rename-if-present). Steam's verify restores them; that is fine.
foreach ($xf in @('libxell.dll','libxess_fg.dll')) {
  $src = Join-Path $xefgDir $xf
  if (Test-Path -LiteralPath $src) { try { Move-Item -Force -LiteralPath $src -Destination ($src + '.disabled') -ErrorAction Stop; L ('disabled XeFG redist ' + $xf) } catch { L ('XeFG disable failed for ' + $xf + ': ' + $_.Exception.Message) } }
}
# UE4SS is loaded by the inline CreateRemoteThread+LoadLibraryW injector below. The
# same class carries the build-locked native patches (crash guards and the null-RHI
# map-fog patches) that are applied right after inject.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class BwInj {
  [DllImport("kernel32")] public static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32")] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, uint sz, uint t, uint p);
  [DllImport("kernel32")] public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, uint sz, uint np, out uint op);
  [DllImport("kernel32")] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] b, uint sz, out UIntPtr r);
  [DllImport("kernel32")] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] b, uint sz, out UIntPtr w);
  [DllImport("kernel32")] public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, uint sz);
  [DllImport("kernel32")] public static extern IntPtr GetModuleHandle(string m);
  [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr h, string p);
  [DllImport("kernel32")] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr a, uint s, IntPtr f, IntPtr p, uint c, IntPtr t);
  private static string Hex(byte[] b, int len) {
    var sb = new System.Text.StringBuilder();
    for(int i=0;i<len && i<b.Length;i++){ if(i>0) sb.Append("-"); sb.Append(b[i].ToString("X2")); }
    return sb.ToString();
  }
  public static int Do(int pid, string dll){
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return -1;
    byte[] b=System.Text.Encoding.Unicode.GetBytes(dll+"\0");
    IntPtr m=VirtualAllocEx(h,IntPtr.Zero,(uint)b.Length,0x3000,4); if(m==IntPtr.Zero) return -2;
    UIntPtr w; if(!WriteProcessMemory(h,m,b,(uint)b.Length,out w)) return -3;
    IntPtr ll=GetProcAddress(GetModuleHandle("kernel32"),"LoadLibraryW"); if(ll==IntPtr.Zero) return -4;
    IntPtr t=CreateRemoteThread(h,IntPtr.Zero,0,ll,m,0,IntPtr.Zero); if(t==IntPtr.Zero) return -5;
    return 0;
  }
  public static string PatchSharedQuestNullPlayer(int pid, long imageBase){
    // Bellwright build 24840601: UMistSharedQuestsComponent::CompleteQuest can be
    // called with AMistPlayer* == null by a shared quest's automatic target update.
    // UMistQuest::TakeReward then passes that null into UMistLoot::GiveToCharacter,
    // which dereferences AActor::GetWorld and crashes. Reuse the component's own
    // controlled-player array when one is present. With no controlled player, return
    // false so completion is deferred instead of losing the reward or crashing.
    const long rva = 0x6AAC5E0;
    byte[] expected = new byte[]{
      0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x55,0x57,0x41,0x56
    };
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n) || n.ToUInt64()!=(ulong)cur.Length) return "ERR ReadProcessMemory";
    bool already = cur[0]==0x48 && cur[1]==0xB8 && cur[10]==0xFF && cur[11]==0xE0 && cur[12]==0x90 && cur[13]==0x90;
    if(already) return "OK already patched UMistSharedQuestsComponent::CompleteQuest RVA 0x6AAC5E0";
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected CompleteQuest prologue at RVA 0x6AAC5E0 got " + Hex(cur, expected.Length);
    }

    // Entry arguments: RCX=component, RDX=quest, R8=player, R9=force.
    // UMistSharedQuestsComponent::ControlledPlayers is a TArray<AMistPlayer*> at
    // +0x180 (data) / +0x188 (count) in this exact build. The trampoline preserves
    // the original 14-byte prologue before returning to CompleteQuest+14.
    byte[] trampoline = new byte[]{
      0x4D,0x85,0xC0,                         // test r8,r8
      0x75,0x1D,                              // jne use_original
      0x83,0xB9,0x88,0x01,0x00,0x00,0x00,    // cmp dword ptr [rcx+188h],0
      0x7E,0x2E,                              // jle return_false
      0x48,0x8B,0x81,0x80,0x01,0x00,0x00,    // mov rax,[rcx+180h]
      0x48,0x85,0xC0,                         // test rax,rax
      0x74,0x22,                              // je return_false
      0x4C,0x8B,0x00,                         // mov r8,[rax]
      0x4D,0x85,0xC0,                         // test r8,r8
      0x74,0x1A,                              // je return_false
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,    // original prologue (filled below)
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x48,0xB8,                              // mov rax,CompleteQuest+14
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0xFF,0xE0,                              // jmp rax
      0x31,0xC0,0xC3                          // return_false: xor eax,eax; ret
    };
    Buffer.BlockCopy(expected,0,trampoline,34,expected.Length);
    Buffer.BlockCopy(BitConverter.GetBytes(addr.ToInt64()+expected.Length),0,trampoline,50,8);
    IntPtr code=VirtualAllocEx(h,IntPtr.Zero,(uint)trampoline.Length,0x3000,0x40);
    if(code==IntPtr.Zero) return "ERR VirtualAllocEx trampoline";
    UIntPtr w;
    if(!WriteProcessMemory(h,code,trampoline,(uint)trampoline.Length,out w) || w.ToUInt64()!=(ulong)trampoline.Length) return "ERR WriteProcessMemory trampoline";
    byte[] verifyCode = new byte[trampoline.Length];
    if(!ReadProcessMemory(h,code,verifyCode,(uint)verifyCode.Length,out n) || n.ToUInt64()!=(ulong)verifyCode.Length) return "ERR verify trampoline ReadProcessMemory";
    for(int i=0;i<trampoline.Length;i++){
      if(verifyCode[i]!=trampoline[i]) return "ERR verify trampoline mismatch got " + Hex(verifyCode, verifyCode.Length);
    }

    byte[] patch = new byte[]{0x48,0xB8,0,0,0,0,0,0,0,0,0xFF,0xE0,0x90,0x90};
    Buffer.BlockCopy(BitConverter.GetBytes(code.ToInt64()),0,patch,2,8);
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx entry";
    bool wrote = WriteProcessMemory(h,addr,patch,(uint)patch.Length,out w) && w.ToUInt64()==(ulong)patch.Length;
    uint discard;
    VirtualProtectEx(h,addr,(uint)patch.Length,oldProtect,out discard);
    if(!wrote) return "ERR WriteProcessMemory entry";
    FlushInstructionCache(h,addr,(uint)patch.Length);
    byte[] verify = new byte[patch.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n) || n.ToUInt64()!=(ulong)verify.Length) return "ERR verify entry ReadProcessMemory";
    for(int i=0;i<patch.Length;i++){
      if(verify[i]!=patch[i]) return "ERR verify entry mismatch got " + Hex(verify, verify.Length);
    }
    return "OK guarded null-player UMistSharedQuestsComponent::CompleteQuest RVA 0x6AAC5E0";
  }
  public static string PatchTickWorldTravel(int pid, long imageBase){
    const long rva = 0x4485B20;
    byte[] expected = new byte[]{0x40,0x55,0x56,0x57,0x48,0x8D,0x6C,0x24,0xB9,0x48,0x81,0xEC,0xE0,0x00,0x00,0x00,0x48,0x8B,0xF1};
    byte[] patch = new byte[]{0xC3,0x90,0x90,0x90,0x90};
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n)) return "ERR ReadProcessMemory";
    bool already=true;
    for(int i=0;i<patch.Length;i++){ if(cur[i]!=patch[i]){ already=false; break; } }
    if(already) return "OK already patched UEngine::TickWorldTravel RVA 0x4485B20";
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected TickWorldTravel prologue at RVA 0x4485B20 got " + Hex(cur, expected.Length);
    }
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx";
    UIntPtr w;
    if(!WriteProcessMemory(h,addr,patch,(uint)patch.Length,out w)) return "ERR WriteProcessMemory";
    FlushInstructionCache(h,addr,(uint)patch.Length);
    uint discard;
    VirtualProtectEx(h,addr,(uint)patch.Length,oldProtect,out discard);
    byte[] verify = new byte[patch.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n)) return "ERR verify ReadProcessMemory";
    for(int i=0;i<patch.Length;i++){
      if(verify[i]!=patch[i]) return "ERR verify mismatch got " + Hex(verify, verify.Length);
    }
    return "OK patched UEngine::TickWorldTravel RVA 0x4485B20: " + Hex(expected, patch.Length) + " -> " + Hex(patch, patch.Length);
  }
  public static string PatchMapFogReveal(int pid, long imageBase){
    const long rva = 0x457E020;
    byte[] expected = new byte[]{0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x83,0xEC,0x70};
    byte[] patch = new byte[]{0xC3,0x90,0x90,0x90,0x90};
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n)) return "ERR ReadProcessMemory";
    bool already=true;
    for(int i=0;i<patch.Length;i++){ if(cur[i]!=patch[i]){ already=false; break; } }
    if(already) return "OK already patched AMapFog::UpdateFogRevealTextures RVA 0x457E020";
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected UpdateFogRevealTextures prologue at RVA 0x457E020 got " + Hex(cur, expected.Length);
    }
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx";
    UIntPtr w;
    if(!WriteProcessMemory(h,addr,patch,(uint)patch.Length,out w)) return "ERR WriteProcessMemory";
    FlushInstructionCache(h,addr,(uint)patch.Length);
    uint discard;
    VirtualProtectEx(h,addr,(uint)patch.Length,oldProtect,out discard);
    byte[] verify = new byte[patch.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n)) return "ERR verify ReadProcessMemory";
    for(int i=0;i<patch.Length;i++){
      if(verify[i]!=patch[i]) return "ERR verify mismatch got " + Hex(verify, verify.Length);
    }
    return "OK patched AMapFog::UpdateFogRevealTextures RVA 0x457E020: " + Hex(expected, patch.Length) + " -> " + Hex(patch, patch.Length);
  }
  public static string PatchMapFogRevealerCanvas(int pid, long imageBase){
    // The original v0.1.77 crash is UMapRevealerComponent::UpdateMapFogAtLocation
    // reading Canvas+0x30 after AMapFog::Tick passes a null Canvas under -nullrhi.
    // Skip only that virtual call in AMapFog::Tick. The actor still runs the rest
    // of its discovery lifecycle, while no host-side render object is touched.
    // Build 24840601 only: unexpected bytes fail closed and keep Lua's full guard.
    const long rva = 0x457D1B7;
    byte[] expected = new byte[]{0xFF,0x90,0x90,0x0A,0x00,0x00};
    byte[] patch = new byte[]{0x90,0x90,0x90,0x90,0x90,0x90};
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n)) return "ERR ReadProcessMemory";
    bool already=true;
    for(int i=0;i<patch.Length;i++){ if(cur[i]!=patch[i]){ already=false; break; } }
    if(already) return "OK already patched AMapFog::Tick revealer Canvas call RVA 0x457D1B7";
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected AMapFog::Tick revealer Canvas call at RVA 0x457D1B7 got " + Hex(cur, expected.Length);
    }
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx";
    UIntPtr w;
    if(!WriteProcessMemory(h,addr,patch,(uint)patch.Length,out w)) return "ERR WriteProcessMemory";
    FlushInstructionCache(h,addr,(uint)patch.Length);
    uint discard;
    VirtualProtectEx(h,addr,(uint)patch.Length,oldProtect,out discard);
    byte[] verify = new byte[patch.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n)) return "ERR verify ReadProcessMemory";
    for(int i=0;i<patch.Length;i++){
      if(verify[i]!=patch[i]) return "ERR verify mismatch got " + Hex(verify, verify.Length);
    }
    return "OK patched AMapFog::Tick revealer Canvas call RVA 0x457D1B7: " + Hex(expected, patch.Length) + " -> " + Hex(patch, patch.Length);
  }
  public static string PatchMapFogRestoreRender(int pid, long imageBase){
    // LoadPersistenceData and RestoreMapFog both finish decoding the persisted fog
    // bytes, then allocate a render command, dispatch it, and synchronously wait for
    // completion. Under -nullrhi the texture upload is invalid. Do not NOP only the
    // dispatch call: that leaves the completion event unsignalled and deadlocks the
    // GameThread. Skip each complete render-command tail after the decoded bytes are
    // already in the AMistMapFog fields, preserving fog persistence without touching
    // a render resource on the headless host.
    long[] rvas = new long[]{0x6A804FF,0x6A827E4};
    byte[][] expected = new byte[][]{
      new byte[]{0x8B,0x85,0xA8,0xFE,0xFF},
      new byte[]{
        0x41,0x8B,0x85,0x10,0x03,0x00,0x00,0xB1,0x01,0x89,0x44,0x24,0x40,
        0x89,0x44,0x24,0x44,0x48,0xC7,0x44,0x24,0x30,0x00,0x00,0x00,0x00,
        0x48,0xC7,0x44,0x24,0x38,0x00,0x00,0x00,0x00,0xE8,0xC4,0x06,0x7C,
        0xFA,0xBA,0x08,0x00,0x00,0x00,0x48,0x89,0x6C,0x24,0x50,0xB9,0x20,
        0x00,0x00,0x00
      }
    };
    byte[][] patches = new byte[][]{
      // Jump to LoadPersistenceData's success epilogue.
      new byte[]{0xE9,0xBB,0x00,0x00,0x00},
      // Restore RestoreMapFog's nonvolatile registers, then jump to its normal
      // security-cookie/stack epilogue. Two trailing NOPs cover the final bytes
      // of the replaced instruction block and are never executed.
      new byte[]{
        0x4C,0x8B,0xBC,0x24,0x90,0x00,0x00,0x00,
        0x4C,0x8B,0xAC,0x24,0xA0,0x00,0x00,0x00,
        0x4C,0x8B,0xA4,0x24,0xA8,0x00,0x00,0x00,
        0x48,0x8B,0xBC,0x24,0xD8,0x00,0x00,0x00,
        0x48,0x8B,0xB4,0x24,0xD0,0x00,0x00,0x00,
        0x48,0x8B,0xAC,0x24,0xC8,0x00,0x00,0x00,
        0xE9,0xBC,0x00,0x00,0x00,0x90,0x90
      }
    };
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr[] addrs = new IntPtr[rvas.Length];
    bool[] already = new bool[rvas.Length];
    UIntPtr n;
    for(int site=0;site<rvas.Length;site++){
      addrs[site] = new IntPtr(imageBase + rvas[site]);
      byte[] patch = patches[site];
      byte[] cur = new byte[expected[site].Length];
      if(!ReadProcessMemory(h,addrs[site],cur,(uint)cur.Length,out n)) return "ERR ReadProcessMemory RVA 0x" + rvas[site].ToString("X");
      already[site]=true;
      for(int i=0;i<patch.Length;i++){ if(cur[i]!=patch[i]){ already[site]=false; break; } }
      if(!already[site]){
        for(int i=0;i<expected[site].Length;i++){
          if(cur[i]!=expected[site][i]) return "ERR unexpected map-fog persistence render enqueue at RVA 0x" + rvas[site].ToString("X") + " got " + Hex(cur, expected[site].Length);
        }
      }
    }
    for(int site=0;site<rvas.Length;site++){
      byte[] patch = patches[site];
      if(!already[site]){
        uint oldProtect;
        if(!VirtualProtectEx(h,addrs[site],(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx RVA 0x" + rvas[site].ToString("X");
        UIntPtr w;
        if(!WriteProcessMemory(h,addrs[site],patch,(uint)patch.Length,out w)) return "ERR WriteProcessMemory RVA 0x" + rvas[site].ToString("X");
        FlushInstructionCache(h,addrs[site],(uint)patch.Length);
        uint discard;
        VirtualProtectEx(h,addrs[site],(uint)patch.Length,oldProtect,out discard);
      }
      byte[] verify = new byte[patch.Length];
      if(!ReadProcessMemory(h,addrs[site],verify,(uint)verify.Length,out n)) return "ERR verify ReadProcessMemory RVA 0x" + rvas[site].ToString("X");
      for(int i=0;i<patch.Length;i++){
        if(verify[i]!=patch[i]) return "ERR verify mismatch RVA 0x" + rvas[site].ToString("X") + " got " + Hex(verify, verify.Length);
      }
    }
    return "OK bypassed AMistMapFog null-RHI render tails after persistence decode RVAs 0x6A804FF and 0x6A827E4";
  }
  public static string PatchSubregionRevealImpl(int pid, long imageBase){
    // UMistRegionManagerComponent::MulticastRevealSubregionsMapFog_Implementation.
    // When a map-revealing structure finishes construction (e.g. a village Scout's
    // Lookout driven by AMistTownStructure::HandleConstructed), the host runs this
    // NetMulticast body locally and it dereferences MapFog internals that never
    // exist under null-RHI -> AV reading 0x0 on the GameThread, and because the
    // completed structure is in the save it re-fires ~150s after every relaunch
    // (permanent crash loop on populated worlds, build 24840601). Ret-stub the local
    // body only: the generated MulticastRevealSubregionsMapFog thunk has already
    // queued the RPC to connected clients before ProcessEvent reaches this body,
    // so joined players still get their map revealed live; only the host-side fog
    // bookkeeping is skipped, which is already inert under null-RHI. FAIL-OPEN on
    // prologue drift like the other fog patches.
    const long rva = 0x6A99FA0;
    byte[] expected = new byte[]{0x40,0x55,0x53,0x57,0x48,0x8D,0x6C,0x24,0xB0,0x48,0x81,0xEC,0x50,0x01,0x00,0x00,0x48,0x8B,0x05,0x09,0x16,0x38};
    byte[] patch = new byte[]{0xC3,0x90,0x90,0x90,0x90};
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n)) return "ERR ReadProcessMemory";
    bool already=true;
    for(int i=0;i<patch.Length;i++){ if(cur[i]!=patch[i]){ already=false; break; } }
    if(already) return "OK already patched MulticastRevealSubregionsMapFog_Implementation RVA 0x6A99FA0";
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected MulticastRevealSubregionsMapFog_Implementation prologue at RVA 0x6A99FA0 got " + Hex(cur, expected.Length);
    }
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)patch.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx";
    UIntPtr w;
    if(!WriteProcessMemory(h,addr,patch,(uint)patch.Length,out w)) return "ERR WriteProcessMemory";
    FlushInstructionCache(h,addr,(uint)patch.Length);
    uint discard;
    VirtualProtectEx(h,addr,(uint)patch.Length,oldProtect,out discard);
    byte[] verify = new byte[patch.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n)) return "ERR verify ReadProcessMemory";
    for(int i=0;i<patch.Length;i++){
      if(verify[i]!=patch[i]) return "ERR verify mismatch got " + Hex(verify, verify.Length);
    }
    return "OK patched MulticastRevealSubregionsMapFog_Implementation RVA 0x6A99FA0: " + Hex(expected, patch.Length) + " -> " + Hex(patch, patch.Length);
  }
  private static string InstallEntryTrampoline(int pid, long imageBase, long rva, string label, byte[] expected, byte[] trampoline, int continuationImmOffset, int continuationOffset){
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess";
    IntPtr addr = new IntPtr(imageBase + rva);
    byte[] cur = new byte[expected.Length];
    UIntPtr n;
    if(!ReadProcessMemory(h,addr,cur,(uint)cur.Length,out n) || n.ToUInt64()!=(ulong)cur.Length) return "ERR ReadProcessMemory " + label;
    bool already = cur.Length>=12 && cur[0]==0x48 && cur[1]==0xB8 && cur[10]==0xFF && cur[11]==0xE0;
    if(already) return "OK already patched " + label + " RVA 0x" + rva.ToString("X");
    for(int i=0;i<expected.Length;i++){
      if(cur[i]!=expected[i]) return "ERR unexpected " + label + " prologue at RVA 0x" + rva.ToString("X") + " got " + Hex(cur, expected.Length);
    }

    Buffer.BlockCopy(BitConverter.GetBytes(addr.ToInt64()+continuationOffset),0,trampoline,continuationImmOffset,8);
    IntPtr code=VirtualAllocEx(h,IntPtr.Zero,(uint)trampoline.Length,0x3000,0x40);
    if(code==IntPtr.Zero) return "ERR VirtualAllocEx " + label + " trampoline";
    UIntPtr w;
    if(!WriteProcessMemory(h,code,trampoline,(uint)trampoline.Length,out w) || w.ToUInt64()!=(ulong)trampoline.Length) return "ERR WriteProcessMemory " + label + " trampoline";
    FlushInstructionCache(h,code,(uint)trampoline.Length);
    byte[] verifyCode = new byte[trampoline.Length];
    if(!ReadProcessMemory(h,code,verifyCode,(uint)verifyCode.Length,out n) || n.ToUInt64()!=(ulong)verifyCode.Length) return "ERR verify " + label + " trampoline ReadProcessMemory";
    for(int i=0;i<trampoline.Length;i++){
      if(verifyCode[i]!=trampoline[i]) return "ERR verify " + label + " trampoline mismatch got " + Hex(verifyCode, verifyCode.Length);
    }

    byte[] entry = new byte[expected.Length];
    for(int i=0;i<entry.Length;i++) entry[i]=0x90;
    entry[0]=0x48; entry[1]=0xB8;
    Buffer.BlockCopy(BitConverter.GetBytes(code.ToInt64()),0,entry,2,8);
    entry[10]=0xFF; entry[11]=0xE0;
    uint oldProtect;
    if(!VirtualProtectEx(h,addr,(uint)entry.Length,0x40,out oldProtect)) return "ERR VirtualProtectEx " + label + " entry";
    bool wrote = WriteProcessMemory(h,addr,entry,(uint)entry.Length,out w) && w.ToUInt64()==(ulong)entry.Length;
    uint discard;
    VirtualProtectEx(h,addr,(uint)entry.Length,oldProtect,out discard);
    if(!wrote) return "ERR WriteProcessMemory " + label + " entry";
    FlushInstructionCache(h,addr,(uint)entry.Length);
    byte[] verify = new byte[entry.Length];
    if(!ReadProcessMemory(h,addr,verify,(uint)verify.Length,out n) || n.ToUInt64()!=(ulong)verify.Length) return "ERR verify " + label + " entry ReadProcessMemory";
    for(int i=0;i<entry.Length;i++){
      if(verify[i]!=entry[i]) return "ERR verify " + label + " entry mismatch got " + Hex(verify, verify.Length);
    }
    return "OK patched " + label + " RVA 0x" + rva.ToString("X");
  }
  public static string PatchPlayerMapManagerOwnership(int pid, long imageBase){
    // Bellwright build 24840601 creates every per-player map manager through
    // UMistMapIconManagerComponent::RegisterPlayerManager with Owner=null. The
    // global icon manager then has no player key for the real remote manager, so
    // all provider updates stay on the pre-join host phantom. The manager
    // component's native Owner is AMistOasisPlayerController, not PlayerState.
    // Resolve Controller->PlayerState (+0x2C8) and call the game's own
    // SetOwnership(PlayerState*) path so RegisteredOwner, old-owner cleanup,
    // provider replay, and deferred update delivery stay internally consistent.
    const long rva = 0x6892080;
    const long setOwnershipRva = 0x68AA830;
    const long controllerSetPlayerStateRva = 0x3BA7B60;
    byte[] expected = new byte[]{
      0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x20
    };
    byte[] setOwnershipExpected = new byte[]{
      0x40,0x53,0x55,0x56,0x48,0x83,0xEC,0x20,0x48,0x8B,0xF2,0x48,0x8B,0xD9
    };
    byte[] controllerSetPlayerStateExpected = new byte[]{
      0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,
      0x80,0x3D,0xF7,0x1E,0x53,0x08,0x00,0x48,0x8B,0xDA,0x48,0x8B,0xF9,0x74,0x53,
      0x48,0x8B,0x81,0xC8,0x02,0x00,0x00
    };
    IntPtr h=OpenProcess(0x1FFFFF,false,pid); if(h==IntPtr.Zero) return "ERR OpenProcess player-map ownership evidence";
    UIntPtr n;
    byte[] setOwnershipCur = new byte[setOwnershipExpected.Length];
    if(!ReadProcessMemory(h,new IntPtr(imageBase+setOwnershipRva),setOwnershipCur,(uint)setOwnershipCur.Length,out n) || n.ToUInt64()!=(ulong)setOwnershipCur.Length) return "ERR ReadProcessMemory UMistPlayerMapIconManagerComponent::SetOwnership";
    for(int i=0;i<setOwnershipExpected.Length;i++){
      if(setOwnershipCur[i]!=setOwnershipExpected[i]) return "ERR unexpected UMistPlayerMapIconManagerComponent::SetOwnership prologue at RVA 0x68AA830 got " + Hex(setOwnershipCur, setOwnershipCur.Length);
    }
    byte[] controllerSetPlayerStateCur = new byte[controllerSetPlayerStateExpected.Length];
    if(!ReadProcessMemory(h,new IntPtr(imageBase+controllerSetPlayerStateRva),controllerSetPlayerStateCur,(uint)controllerSetPlayerStateCur.Length,out n) || n.ToUInt64()!=(ulong)controllerSetPlayerStateCur.Length) return "ERR ReadProcessMemory AController::SetPlayerState";
    for(int i=0;i<controllerSetPlayerStateExpected.Length;i++){
      if(controllerSetPlayerStateCur[i]!=controllerSetPlayerStateExpected[i]) return "ERR unexpected AController::SetPlayerState evidence at RVA 0x3BA7B60 got " + Hex(controllerSetPlayerStateCur, controllerSetPlayerStateCur.Length);
    }
    byte[] trampoline = new byte[]{
      0x4D,0x85,0xC0,                         // test r8,r8
      0x75,0x38,                              // jne original
      0x48,0x85,0xD2,                         // test rdx,rdx
      0x74,0x33,                              // je original
      0x4C,0x8B,0x92,0xB0,0x00,0x00,0x00,    // mov r10,[rdx+0B0h] (component Owner/controller)
      0x4D,0x85,0xD2,                         // test r10,r10
      0x74,0x27,                              // je original
      0x4D,0x8B,0x92,0xC8,0x02,0x00,0x00,    // mov r10,[r10+2C8h] (controller PlayerState)
      0x4D,0x85,0xD2,                         // test r10,r10
      0x74,0x1B,                              // je original
      0x48,0x83,0xEC,0x28,                   // sub rsp,28h (shadow space + call alignment)
      0x48,0x8B,0xCA,                         // mov rcx,rdx (player manager this)
      0x49,0x8B,0xD2,                         // mov rdx,r10 (owning PlayerState)
      0x48,0xB8,                              // mov rax,SetOwnership
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0xFF,0xD0,                              // call rax
      0x48,0x83,0xC4,0x28,                   // add rsp,28h
      0xC3,                                   // return; SetOwnership registered the manager
      0x00,0x00,0x00,0x00,0x00,              // original prologue (filled below)
      0x00,0x00,0x00,0x00,0x00,
      0x00,0x00,0x00,0x00,0x00,
      0x49,0xBB,                              // mov r11,RegisterPlayerManager+15
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x41,0xFF,0xE3                          // jmp r11
    };
    Buffer.BlockCopy(BitConverter.GetBytes(imageBase+setOwnershipRva),0,trampoline,46,8);
    Buffer.BlockCopy(expected,0,trampoline,61,expected.Length);
    return InstallEntryTrampoline(pid,imageBase,rva,"UMistMapIconManagerComponent::RegisterPlayerManager owner fallback",expected,trampoline,78,expected.Length);
  }
  public static string PatchHarvestingOrderNullData(int pid, long imageBase){
    // A remote harvesting-order request can reach
    // UMistTownHarvestingStructureData::ServerCreateOrder with this==null and AV
    // on the first field read at +0x310. A missing structure-data object cannot
    // accept an order, so leave the request uncommitted instead of crashing.
    const long rva = 0x6431290;
    byte[] expected = new byte[]{
      0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18
    };
    byte[] trampoline = new byte[]{
      0x48,0x85,0xC9,                         // test rcx,rcx
      0x74,0x1C,                              // je return_void
      0x00,0x00,0x00,0x00,0x00,              // original prologue (filled below)
      0x00,0x00,0x00,0x00,0x00,
      0x00,0x00,0x00,0x00,0x00,
      0x49,0xBB,                              // mov r11,ServerCreateOrder+15
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x41,0xFF,0xE3,                         // jmp r11
      0xC3                                    // return_void
    };
    Buffer.BlockCopy(expected,0,trampoline,5,expected.Length);
    return InstallEntryTrampoline(pid,imageBase,rva,"UMistTownHarvestingStructureData::ServerCreateOrder null-data guard",expected,trampoline,22,expected.Length);
  }
  public static string PatchConnectionToRoadNullContext(int pid, long imageBase){
    // The dedicated host has no local road-preview context at Controller+0x7D8.
    // ClientReturnConnectionToRoad nevertheless dereferences it during an ordinary
    // remote building placement, crashing at +0x0B. Return when either nested
    // context is absent; the client receives no stale placement correction.
    const long rva = 0x6B4AA10;
    byte[] expected = new byte[]{
      0x48,0x83,0xEC,0x48,
      0x48,0x8B,0x81,0xD8,0x07,0x00,0x00,
      0x48,0x8B,0x88,0x98,0x0F,0x00,0x00
    };
    byte[] trampoline = new byte[]{
      0x48,0x85,0xC9,                         // test rcx,rcx
      0x74,0x2E,                              // je return_direct
      0x48,0x83,0xEC,0x48,                    // sub rsp,48h
      0x48,0x8B,0x81,0xD8,0x07,0x00,0x00,    // mov rax,[rcx+7D8h]
      0x48,0x85,0xC0,                         // test rax,rax
      0x74,0x19,                              // je unwind
      0x48,0x8B,0x88,0x98,0x0F,0x00,0x00,    // mov rcx,[rax+0F98h]
      0x48,0x85,0xC9,                         // test rcx,rcx
      0x74,0x0D,                              // je unwind
      0x49,0xBB,                              // mov r11,ClientReturnConnectionToRoad+18
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x41,0xFF,0xE3,                         // jmp r11
      0x48,0x83,0xC4,0x48,                    // unwind: add rsp,48h
      0xC3,                                   // ret
      0xC3                                    // return_direct: ret
    };
    return InstallEntryTrampoline(pid,imageBase,rva,"AMistOasisPlayerController::ClientReturnConnectionToRoad_Implementation null-context guard",expected,trampoline,35,expected.Length);
  }
  public static string PatchTemporaryUiContextNullManager(int pid, long imageBase){
    // Settlement interactions can call UMistUIManager::CreateTemporaryContext on
    // a dedicated host where the UI manager is null. The function returns its
    // context through the hidden RDX result pointer, so return an empty context
    // without touching render/UI state.
    const long rva = 0x68F5040;
    byte[] expected = new byte[]{
      0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x56,0x57
    };
    byte[] trampoline = new byte[]{
      0x48,0x85,0xC9,                         // test rcx,rcx
      0x74,0x19,                              // je empty_context
      0x00,0x00,0x00,0x00,0x00,              // original prologue (filled below)
      0x00,0x00,0x00,0x00,0x00,
      0x00,0x00,
      0x49,0xBB,                              // mov r11,CreateTemporaryContext+12
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x41,0xFF,0xE3,                         // jmp r11
      0x31,0xC0,                              // empty_context: xor eax,eax
      0x48,0x89,0x02,                         // mov [rdx],rax
      0x48,0x8B,0xC2,                         // mov rax,rdx
      0xC3                                    // ret
    };
    Buffer.BlockCopy(expected,0,trampoline,5,expected.Length);
    return InstallEntryTrampoline(pid,imageBase,rva,"UMistUIManager::CreateTemporaryContext null-manager guard",expected,trampoline,19,expected.Length);
  }
}
"@ -ErrorAction SilentlyContinue
$cores = [int]$env:NUMBER_OF_PROCESSORS; if ($cores -lt 1) { $cores = 1 }
if ($K -gt $cores) { $K = $cores }
$doPin = ($K -gt 0 -and $K -lt $cores)
$startBit = $slot * $K
[uint64]$mask = 0
if ($doPin) {
  $usableLanes = [math]::Min($cores, 64)
  $tileCount = [math]::Max(1, [math]::Floor($usableLanes / $K))
  $rawSlot = $slot
  $slot = $slot % $tileCount
  if ($slot -ne $rawSlot) { L ('affinity slot folded raw=' + $rawSlot + ' -> tile=' + $slot + ' (tiles=' + $tileCount + ', K=' + $K + ', lanes=' + $usableLanes + ')') }
  $startBit = $slot * $K
  for ($i = 0; $i -lt $K; $i++) { $mask = $mask -bor ([uint64]1 -shl ($startBit + $i)) }
  if ($mask -eq 0) { $mask = [uint64]1 }
}
$env:HEARTH_HOST_LOG = $hostLog
$env:BW_HOST_LOG = $hostLog
# Apply the CPU-affinity pin + process priority to the game process. Called right
# after launch AND re-asserted after the port binds (the game can reset its own
# affinity/priority during engine init). FAIL CLOSED on a pin failure: an un-pinned
# WARP host busy-polls all cores and can melt the shared box, so if we cannot land the
# mask we return $false and the caller kills + retries rather than leaving it unpinned.
# Priority = AboveNormal so the game's threads win scheduling WITHIN the pinned set
# (never High/Realtime — that would starve the box's own services).
function Set-GamePin([int]$cpid, [bool]$quiet = $false) {
  if (-not $doPin) {
    # pinning disabled (K >= cores) — still nudge priority, but don't fail on it.
    try { (Get-Process -Id $cpid -ErrorAction Stop).PriorityClass = 'AboveNormal' } catch {}
    return $true
  }
  try {
    $p = Get-Process -Id $cpid -ErrorAction Stop
    $beforeAffinity = [int64]$p.ProcessorAffinity
    $beforePriority = $p.PriorityClass
    $p.ProcessorAffinity = [IntPtr][int64]$mask
    $p.PriorityClass = 'AboveNormal'
    Start-Sleep -Milliseconds 200
    $p2 = Get-Process -Id $cpid -ErrorAction Stop
    if (([int64]$p2.ProcessorAffinity) -ne ([int64]$mask)) {
      L ('PIN FAILED: affinity readback ' + ([int64]$p2.ProcessorAffinity) + ' != mask ' + ([int64]$mask))
      return $false
    }
    if ((-not $quiet) -or $beforeAffinity -ne ([int64]$mask) -or $beforePriority -ne 'AboveNormal') {
      L ('pinned pid=' + $cpid + ' affinity=' + ([int64]$mask) + ' (0x' + ('{0:X}' -f ([int64]$mask)) + ', ' + $K + ' cores, slot ' + $slot + ') priority=' + $p2.PriorityClass)
    }
    return $true
  } catch { L ('PIN FAILED (exception): ' + $_.Exception.Message); return $false }
}

# v0.1.42: the WARP-era EventPairLow demotion is GONE. Under -nullrhi there is no
# WARP spin pool, and the old demote-to-Lowest sweep was a one-way ratchet that
# (re-asserted every 15s) progressively caught UE's own task/render workers whenever
# they were sampled mid-wait — ~40 threads ended up permanently at Lowest on live
# hosts. Keep only the main/game-thread TimeCritical boost (cheap, bounded by the
# affinity mask), and pick the main thread defensively: threads that have already
# exited throw on StartTime, which used to blow up the Sort-Object pipeline.
function Set-GameThreadPriorities([int]$cpid, [bool]$quiet = $false) {
  try {
    $p = Get-Process -Id $cpid -ErrorAction Stop
    $main = $null
    $best = [DateTime]::MaxValue
    foreach ($th in $p.Threads) {
      try { if ($th.StartTime -lt $best) { $best = $th.StartTime; $main = $th } } catch {}
    }
    if ($main) {
      try {
        if ($main.PriorityLevel -ne 'TimeCritical') {
          $main.PriorityLevel = 'TimeCritical'
          if (-not $quiet) { L ('threadprio boosted main tid=' + $main.Id + ' -> TimeCritical') }
        }
      } catch { if (-not $quiet) { L ('threadprio main boost failed tid=' + $main.Id + ': ' + $_.Exception.Message) } }
    }
    return $true
  } catch { L ('threadprio FAILED (exception): ' + $_.Exception.Message); return $false }
}
function Launch-SP {
  if (-not (Protect-Save)) { return 0 }
  # Plain Start-Process — no CREATE_SUSPENDED / P/Invoke. Affinity (when pinning
  # is enabled) is applied immediately after start; the game spawns its worker
  # threads seconds later, so the brief window before the mask lands is benign.
  $argList = $spArgs
  try {
    $proc = Start-Process -FilePath $spExePath -ArgumentList $argList -WorkingDirectory $workDir -PassThru -WindowStyle Hidden -ErrorAction Stop
  } catch { L ('Start-Process FAILED: ' + $_.Exception.Message); return 0 }
  if (-not $proc) { L 'Start-Process returned null'; return 0 }
  $cpid = $proc.Id
  # Initial pin. A failure here is non-fatal (engine init can briefly reject the set);
  # the decisive pin is the post-boot re-assert in Start-HostWithRetry, which fails
  # closed. We still try here to bound the WARP busy-poll from the first second.
  Set-GamePin $cpid | Out-Null
  return $cpid
}
# UE4SS / plugin load via inline CreateRemoteThread+LoadLibraryW (BwInj). The
# compiled supervisor's "inject" verb is non-functional in HearthServer v0.1.x, so we
# inject directly. When $readyLog is set we wait (up to $readyTimeout) for UE4SS to
# write its log = init confirmed; with $reinject we retry the LoadLibrary call.
function Inject-Dll([int]$cpid, [string]$dllPath, [string]$label, [string]$readyLog = '', [int]$readyTimeout = 36, [int]$reinject = 1, [switch]$optional) {
  if (-not (Test-Path -LiteralPath $dllPath)) {
    if ($optional) { L ($label + ' inject skipped (optional dll absent): ' + $dllPath); return $true }
    L ($label + ' inject FAILED: dll missing at ' + $dllPath); return $false
  }
  for ($try = 0; $try -le $reinject; $try++) {
    $rc = [BwInj]::Do($cpid, $dllPath)
    L ($label + ' CRT inject rc=' + $rc + ' pid=' + $cpid + ' try=' + $try)
    if ($readyLog -eq '') { if ($rc -eq 0) { return $true } else { Start-Sleep -Seconds 2; continue } }
    # wait for the ready-log to appear (UE4SS init)
    for ($k = 0; $k -lt [int]($readyTimeout / 3); $k++) {
      Start-Sleep -Seconds 3
      if (Test-Path -LiteralPath $readyLog) { L ($label + ' inject OK (ready-log present) pid=' + $cpid); return $true }
      if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { L ($label + ' inject: host died waiting ready-log'); return $false }
    }
    L ($label + ' inject: ready-log not present after ' + $readyTimeout + 's — reinject')
  }
  L ($label + ' inject FAILED after ' + ($reinject + 1) + ' tries')
  return $false
}
function Start-HostWithRetry {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    if (Test-Path -LiteralPath $stopMarker) { L 'stop requested during launch -> abort'; return 0 }
    Remove-Item -LiteralPath $hostLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fogPatchMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $gameplaySettingsStatus -Force -ErrorAction SilentlyContinue
    $fogPatchToken = [Guid]::NewGuid().ToString('N')
    $env:HEARTH_MAP_FOG_PATCH_MARKER = $fogPatchMarker
    $env:HEARTH_MAP_FOG_PATCH_TOKEN = $fogPatchToken
    L ('launch attempt ' + $attempt + ' cores=' + $cores + ' K=' + $K + ' doPin=' + $doPin + ' mask=' + $mask)
    Remove-Item -LiteralPath $ue4ssLog -Force -ErrorAction SilentlyContinue
    # clear the UE abslog so the pre-bind map-load detection below only matches THIS attempt
    Remove-Item -LiteralPath $ueLog -Force -ErrorAction SilentlyContinue
    $cpid = Launch-SP
    if ($cpid -eq 0) { Start-Sleep -Seconds 3; continue }
    # Inject EARLY (~0.4s), mid engine-init FName storm. On-box validation 2026-06-14:
    # injecting at an IDLE menu makes UE4SS spin forever "Verifying FName constructor"
    # (the posthook waits for an in-game FName call the idle menu never makes); injecting
    # during init catches the FName storm so verification passes. v0.1.42 GOTCHA: under
    # -nullrhi a hot-cache boot reaches the idle menu in ~1.2s, so the old 2s delay LOST
    # the race fleet-wide (game wedged at menu, bw_host never loaded, no bind). 400ms is
    # safely inside even the fastest observed init; UE4SS's normal deployment is a t=0
    # proxy load, so earlier is strictly safer. The bw_host mod's own settled-menu gate
    # (not the inject delay) is what waits for the menu before hosting.
    Start-Sleep -Milliseconds 400
    if (Test-Path -LiteralPath $stopMarker) { L 'stop requested after boot -> abort'; try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}; return 0 }
    if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { L ('host pid ' + $cpid + ' died during boot — retry'); continue }
    # UE4SS load, performed by the compiled supervisor exe. UE4SS writes UE4SS.log
    # once it initializes -> the exe retries up to 3x and returns success only once
    # that log appears.
    $ue4ssReady = Inject-Dll $cpid $ue4ssDll 'UE4SS' $ue4ssLog 36 3
    if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { L 'host died during/after inject — retry'; continue }
    if (-not $ue4ssReady) { L 'UE4SS never initialized after 3 injects — kill + retry'; try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}; continue }
    # UE4SS live -> bw_host loads the mod stack (scan budget up to 180s on
    # 5.7), swaps NetDriver -> IpNetDriver and calls HostGame() -> gameplay UDP binds.
    #
    # SHARED QUEST NULL-PLAYER PATCH (build 24840601): automatic shared-quest
    # completion can reach TakeReward with no AMistPlayer and crash in
    # UMistLoot::GiveToCharacter. Substitute the component's first controlled
    # player, or defer completion when nobody is controlled, before world play begins.
    try {
      $gameProc0 = Get-Process -Id $cpid -ErrorAction Stop
      $questRes = [BwInj]::PatchSharedQuestNullPlayer($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native shared-quest player patch: ' + $questRes)
    } catch { L ('native shared-quest player patch EXCEPTION: ' + $_.Exception.Message) }
    #
    # PLAYER MAP OWNERSHIP + DEDICATED-CONTEXT GUARDS (build 24840601):
    # Bellwright registers new per-player map managers with a null owner on the
    # dedicated path, so the real remote manager never receives the provider
    # backlog while the hidden host manager grows without bound. Recover the
    # owning PlayerState through the component's PlayerController and enter the
    # game's normal SetOwnership/provider replay path. Three unrelated remote
    # gameplay paths also assume local
    # harvesting, road-preview, or UI context that a dedicated host does not have;
    # guard only those measured null chains before the world becomes joinable.
    try {
      $gameProc0 = Get-Process -Id $cpid -ErrorAction Stop
      $mapOwnerRes = [BwInj]::PatchPlayerMapManagerOwnership($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native player-map ownership patch: ' + $mapOwnerRes)
      $harvestRes = [BwInj]::PatchHarvestingOrderNullData($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native harvesting-order null-data patch: ' + $harvestRes)
      $roadRes = [BwInj]::PatchConnectionToRoadNullContext($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native road-placement null-context patch: ' + $roadRes)
      $uiRes = [BwInj]::PatchTemporaryUiContextNullManager($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native settlement-UI null-manager patch: ' + $uiRes)
    } catch { L ('native player-map/crash patch EXCEPTION: ' + $_.Exception.Message) }
    #
    # NULLRHI FOG PATCHES (build 24840601): the original v0.1.77 crash stack lands
    # in UMapRevealerComponent::UpdateMapFogAtLocation after AMapFog::Tick passes a
    # null Canvas under -nullrhi. Skip that exact virtual call while preserving the
    # rest of the actor lifecycle. AMapFog::UpdateFogRevealTextures also AVs with no
    # RHI as soon as a world with fog-reveal state ticks its MapFog actor.
    # AMistMapFog::LoadPersistenceData and RestoreMapFog have the same null-RHI
    # dependency while loading an existing world: they expand the saved fog bytes
    # safely, then queue a render-thread texture upload that AVs. bw_host's Lua fog
    # guard registers
    # NotifyOnNewObject + a 5s sweep, but on these worlds the actor's first tick fires
    # before the Lua neuter lands, so the guard loses the race. Ret-stub the function
    # at inject time instead — deterministic, and the world load only starts at the
    # bw_host settled-menu gate (~t=19s), long after this point. The native update
    # patch ret-stubs the unsafe texture function. The persistence patch bypasses both
    # render enqueues only after the persisted bytes are decoded, so a later autosave
    # preserves the fog data. The actor-only Lua path is authorized only when all
    # four build-locked patches verify; every owned component tick remains disabled.
    # Any mismatch keeps the existing full MapFog guard. The
    # subregion-reveal patch ret-stubs the local NetMulticast body that fires when a
    # map-revealing structure (Scout's Lookout) finishes construction — it AVs on
    # null fog internals and crash-loops populated worlds; clients
    # still receive the multicast and reveal fog live.
    try {
      $gameProc0 = Get-Process -Id $cpid -ErrorAction Stop
      $fogRes = [BwInj]::PatchMapFogReveal($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native fog-reveal patch: ' + $fogRes)
      $fogCanvasRes = [BwInj]::PatchMapFogRevealerCanvas($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native fog-revealer-canvas patch: ' + $fogCanvasRes)
      $fogRestoreRes = [BwInj]::PatchMapFogRestoreRender($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native fog-restore patch: ' + $fogRestoreRes)
      $fogSubregionRes = [BwInj]::PatchSubregionRevealImpl($cpid, $gameProc0.MainModule.BaseAddress.ToInt64())
      L ('native fog-subregion-reveal patch: ' + $fogSubregionRes)
      $fogPatchesReady = $fogActorEnabled -and $fogRes.StartsWith('OK') -and $fogCanvasRes.StartsWith('OK') -and $fogRestoreRes.StartsWith('OK') -and $fogSubregionRes.StartsWith('OK')
      if ($fogPatchesReady) {
        [IO.File]::WriteAllText($fogPatchMarker, $fogPatchToken, [System.Text.Encoding]::ASCII)
        L 'native fog actor authorization: four patches verified; actor-only mode enabled'
      } else {
        Remove-Item -LiteralPath $fogPatchMarker -Force -ErrorAction SilentlyContinue
        L 'native fog actor authorization: not authorized; full Lua guard retained'
      }
    } catch {
      Remove-Item -LiteralPath $fogPatchMarker -Force -ErrorAction SilentlyContinue
      L ('native fog patch EXCEPTION: ' + $_.Exception.Message)
    }
    #
    # EARLY no-rebrowse patch (populated-world fix, 2026-07-01) — disabled on build
    # 24840601.  This host path logs "Loaded OasisGameMode" for the initial menu world before
    # bw_host fires its listen OpenLevel, so the early patch returns from TickWorldTravel
    # too soon and the listen travel bounces without constructing a NetDriver.  The post-bind
    # ret-stub also crash-looped the prior build, so leave TickWorldTravel intact for 24840601.
    L 'early no-rebrowse patch skipped for Bellwright build 24840601'
    # Previous behavior:
    # The Mist GameMode self-restarts ~48s after the match reaches InProgress:
    # UEngine::Browse -> LoadMap -> full-GC purge (FinishDestroy on ~69k Texture2D). On a
    # FRESH world the port binds in ~40s and the launcher patches TickWorldTravel just
    # before that ~48s trigger, so the purge never runs. On a POPULATED world the load
    # itself takes minutes, so the self-restart fires DURING the load, BEFORE the port
    # binds; under WARP that purge hangs the game thread for tens of minutes and the host
    # never binds (observed on a populated world: ~10 cores pegged, 2.7GB->0.5GB purge, no bind in
    # 30min). Fix: apply the TickWorldTravel patch as soon as the listen map has loaded
    # ("Loaded OasisGameMode" in the abslog) -> AFTER the initial OpenLevel travel is done
    # (that log line only prints once the map finished loading, so the patch cannot block
    # the initial load) and BEFORE the ~48s self-restart -> the purge never fires and the
    # populated load can finish and bind. Idempotent (post-bind call below returns "already
    # patched"); harmless for fresh worlds (patched a few seconds earlier than before).
    if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { continue }
    # UP = gameplay UDP bound (host joinable). Populated worlds are CPU-bound under WARP and
    # can take several minutes to finish loading even with the self-restart purge patched
    # out, so allow a generous window and bail early only on a real idle deadlock.
    $up = $false
    $prevCpuMs = -1.0
    $idleTicks = 0
    for ($b = 0; $b -lt 300; $b++) {   # 300 * 3s = 900s (15 min) hard cap per attempt
      Start-Sleep -Seconds 3
      if (Test-Path -LiteralPath $stopMarker) { L 'stop requested during host bringup -> abort'; try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}; return 0 }
      $gp = Get-Process -Id $cpid -ErrorAction SilentlyContinue
      if (-not $gp) { L ('host pid ' + $cpid + ' died during mod scan/HostGame — retry'); break }
      if (Get-NetUDPEndpoint -LocalPort $gameplayPort -ErrorAction SilentlyContinue) { $up = $true; break }
      $cpuMs = 0.0; try { $cpuMs = $gp.TotalProcessorTime.TotalMilliseconds } catch {}
      if ($prevCpuMs -ge 0) {
        if (($cpuMs - $prevCpuMs) -lt 60) { $idleTicks++ } else { $idleTicks = 0 }
      }
      $prevCpuMs = $cpuMs
      if ($idleTicks -ge 80) { L ('gameplay UDP ' + $gameplayPort + ' never bound — process idle ~240s (deadlock, not a slow load) — kill + retry'); break }
    }
    if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { continue }
    if ($up) {
      # TickWorldTravel ret-stub is disabled for Bellwright build 24840601.  The host reaches
      # listen with the patch skipped, while applying it after bind exits the process within
      # ~15s.  Keep the injector method compiled for the next build cut, but do not invoke it
      # on this pinned build.
      L 'native no-rebrowse patch skipped for Bellwright build 24840601'
      # RE-ASSERT the CPU pin now that the port is bound: the game resets its own
      # affinity/priority during engine init + the WorldPartition stream, so the pin
      # set at launch can be gone by now. This is the DECISIVE pin (the WARP worker pool
      # is fully spun up by here). FAIL CLOSED — an un-pinned WARP host busy-polls all
      # cores and can melt the shared box, so kill + retry if the mask won't land.
      if (-not (Set-GamePin $cpid)) {
        L 'post-boot pin failed - kill + retry (refuse to run an un-pinned WARP host on a shared box)'
        try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 3
        continue
      }
      Set-GameThreadPriorities $cpid | Out-Null
      # Optional native net-ID plugin (absent in v1 -> the compiled exe exits 0/skip
      # on missing file via --optional).
      Inject-Dll $cpid $pluginDll 'HearthPlugin' '' 36 1 -optional | Out-Null
      $cpid | Set-Content -Encoding ASCII $pidFile
      L ('Bellwright host UP pid=' + $cpid + ' (UE4SS + bw_host, gameplay UDP ' + $gameplayPort + ' bound)')
      return $cpid
    } else {
      L ('gameplay UDP ' + $gameplayPort + ' never bound (bw_host did not bring the host up) — kill + retry')
      try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  return 0
}
# clear stale stop/restart markers so a fresh start is clean
Remove-Item -LiteralPath $stopMarker -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $restartReq -Force -ErrorAction SilentlyContinue
# write the supervisor pid BEFORE the initial launch so a concurrent stop can kill us even
# during the boot/inject window (Start-HostWithRetry also aborts if $stopMarker appears).
try { $PID | Set-Content -Encoding ASCII $supPidFile } catch {}
# Start the HearthServer A2S/query responder FIRST (before the game) so the query port is
# answering as early as possible; the loop below keeps it alive for the host's whole life.
$sup = Start-Hearthserver
Start-Sleep -Seconds 2
$cpid = Start-HostWithRetry
if ($cpid -eq 0) { L 'Bellwright host did not come up (launch failed or stop-aborted) — reaping supervisor'; if ($sup) { try { Stop-Process -Id $sup.Id -Force -ErrorAction SilentlyContinue } catch {} }; Remove-Item -LiteralPath $supPidFile -Force -ErrorAction SilentlyContinue; return }
# SUPERVISOR LOOP: recycle the host on the mod's restart-request
# and relaunch on crash.  HearthServer (A2S/RCON/HTTP) stays up across recycles — only
# the game process bounces.  Stop/restart writes $stopMarker (LEFT in place for the next
# start to clear) AND kills this pid, so the loop cannot relaunch after a stop.
L ('supervisor loop start sup_pid=' + $PID)
function Reap-Crash {
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'CrashReportClient*' -or $_.ProcessName -eq 'WerFault' -or $_.ProcessName -eq 'WerFaultSecure' } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  Get-Process crashpad_handler -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Path).StartsWith($workDir, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
$failCount = 0
while ($true) {
  Start-Sleep -Seconds 15
  if (Test-Path -LiteralPath $stopMarker) { L 'stop marker -> supervisor exit (no relaunch)'; break }
  # KEEP HEARTHSERVER (the A2S/query responder) ALIVE — every iteration, independent of the
  # game's state. If it died (crash/exit), the query port goes dark and the launcher shows
  # the server Offline even though gameplay UDP is still bound. Relaunch it immediately so
  # A2S answers continuously for the host's entire life, including a long zero-player idle.
  if (-not (Test-HearthserverAlive $sup)) {
    L 'HearthServer (A2S/query responder) not alive -> relaunching'
    $sup = Start-Hearthserver
  }
  $recycle = Test-Path -LiteralPath $restartReq
  $alive = [bool](Get-Process -Id $cpid -ErrorAction SilentlyContinue)
  if ($alive) { Set-GamePin $cpid $true | Out-Null; Set-GameThreadPriorities $cpid $true | Out-Null }
  if (-not ($recycle -or (-not $alive))) { continue }
  if ($recycle) {
    L 'restart-request -> recycle host'
    Remove-Item -LiteralPath $restartReq -Force -ErrorAction SilentlyContinue
    if ($alive) { try { Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 4 }
  } else { L ('host pid ' + $cpid + ' gone (crash/exit) -> relaunch') }
  Reap-Crash
  if (Test-Path -LiteralPath $stopMarker) { L 'stop marker before relaunch -> supervisor exit'; break }
  $cpid = Start-HostWithRetry
  if ($cpid -eq 0) {
    $failCount++
    L ('relaunch FAILED (consecutive=' + $failCount + ')')
    if ($failCount -ge 5) { L 'too many consecutive relaunch failures -> reaping supervisor + HearthServer (unhealthy; run the script again once the cause is fixed)'; if ($sup) { try { Stop-Process -Id $sup.Id -Force -ErrorAction SilentlyContinue } catch {} }; break }
    Start-Sleep -Seconds ([math]::Min(60, 10 * $failCount))
  } else { $failCount = 0 }
}
Remove-Item -LiteralPath $supPidFile -Force -ErrorAction SilentlyContinue
