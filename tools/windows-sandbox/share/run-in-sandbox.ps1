# Runs automatically inside Windows Sandbox (see signagex-sandbox.wsb).
#
# Windows Sandbox is isolated and ephemeral -- its filesystem isn't visible
# from the host and everything is destroyed on close, which is why the
# player's debug log has been unreadable for every sandbox test so far.
# C:\share is mapped read-write to a real host folder, so anything written
# there IS readable from the host while the sandbox is still running.
#
# ORDER MATTERS, and the previous version had it wrong. It ran a full
# network self-test AND a silent install before the player ever started,
# which delayed launch by a minute or more. That is precisely the window in
# which Windows settles its internet determination -- so the harness masked
# the very failure it was built to capture: the player connected fine under
# the harness, and failed when the same build was launched immediately in a
# plain sandbox.
#
# So now:
#   1. Start mirroring logs out to C:\share\logs FIRST, in a separate
#      process, so nothing below can delay or break log capture.
#   2. Get the player running as fast as possible (a plain extracted build
#      is preferred over the installer precisely because it is faster and
#      therefore reproduces the startup race).
#   3. Only THEN run the network self-test, concurrently with the running
#      app. It still answers "can this sandbox reach the backend at all",
#      it just no longer buys the app a minute of free settling time.

$ErrorActionPreference = 'Continue'
$share = 'C:\share'
$diag  = Join-Path $share 'sandbox-diag.txt'
$logs  = Join-Path $share 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Say($msg) {
  $line = "$(Get-Date -Format 'HH:mm:ss.fff')  $msg"
  Add-Content -Path $diag -Value $line -Encoding utf8
}

Set-Content -Path $diag -Value "SignageX sandbox diagnostics - $(Get-Date)" -Encoding utf8
Say "=== HARNESS START (log mirroring first, launch second, diagnostics last) ==="

# ---------- 1. log mirroring, in its own process, started FIRST ----------
# Detached so a hang or error anywhere below cannot stop log capture -- the
# log is the entire point of running in the sandbox at all.
$mirrorScript = @'
$logs = "C:\share\logs"
$appLog = Join-Path $env:APPDATA "SignageX\SignageX Player\signagex_debug.log"
while ($true) {
  try {
    if (Test-Path $appLog) {
      Copy-Item $appLog (Join-Path $logs "signagex_debug.log") -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem "$env:LOCALAPPDATA" -Filter "SignageX*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($n in @("watchdog.log","watchdog.log.previous")) {
        $w = Join-Path $_.FullName $n
        if (Test-Path $w) { Copy-Item $w (Join-Path $logs "$($_.Name)-$n") -Force -ErrorAction SilentlyContinue }
      }
    }
  } catch { }
  Start-Sleep -Seconds 2
}
'@
$mirrorPath = Join-Path $env:TEMP 'mirror-logs.ps1'
Set-Content -Path $mirrorPath -Value $mirrorScript -Encoding utf8
Start-Process powershell.exe -ArgumentList '-ExecutionPolicy','Bypass','-NoProfile','-WindowStyle','Hidden','-File',$mirrorPath
Say "log mirroring started -> $logs"

# ---------- 2. launch the player as fast as possible ----------
# A pre-extracted build wins over the installer: it starts in seconds
# instead of a minute, which is what makes the startup race reproducible.
# Drop EITHER digital_signage-production.zip (preferred) OR the Setup .exe
# into the shared folder.
$zip = Get-ChildItem -Path $share -Filter '*.zip' -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -like '*digital_signage*' } | Select-Object -First 1
$exe = $null

if ($zip) {
  Say "=== EXTRACTING $($zip.Name) (fast path -- preserves the startup race) ==="
  $dest = 'C:\player'
  try {
    Expand-Archive -Path $zip.FullName -DestinationPath $dest -Force
    $exe = Get-ChildItem $dest -Recurse -Filter 'SignageXPlayer.exe' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) {
      # Some artifact zips nest the Release folder one level deeper.
      $exe = Get-ChildItem $dest -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike '*Setup*' -and $_.Name -notlike '*unins*' } |
             Select-Object -First 1
    }
  } catch { Say "  extract FAILED: $_" }
}

if (-not $exe) {
  $installer = Get-ChildItem -Path $share -Filter '*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like '*Setup*' -or $_.Name -like '*SignageX*' } |
               Select-Object -First 1
  if ($installer) {
    Say "=== INSTALLING $($installer.Name) (slower -- may mask a startup race) ==="
    $p = Start-Process -FilePath $installer.FullName `
         -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/RESTARTPLAYER=1' -PassThru -Wait
    Say "  installer exited with $($p.ExitCode)"
    $appDir = Get-ChildItem "$env:LOCALAPPDATA" -Directory -Filter 'SignageX*' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1
    if ($appDir) { $exe = Get-ChildItem $appDir.FullName -Filter 'SignageXPlayer.exe' | Select-Object -First 1 }
  }
}

if ($exe) {
  Say "=== LAUNCHING $($exe.FullName) ==="
  Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName
  Say "  launched at $(Get-Date -Format 'HH:mm:ss.fff') -- diagnostics below run CONCURRENTLY"
} else {
  Say "=== NOTHING TO RUN: put digital_signage-production.zip or the Setup .exe in C:\share ==="
}

# ---------- 3. diagnostics, now that the app is already running ----------
Say "=== TIME / TIMEZONE ==="
Say "local=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')  tz=$((Get-TimeZone).Id)"

Say "=== ADAPTERS ==="
Get-NetAdapter | ForEach-Object { Say ("  {0} | {1} | status={2} | speed={3}" -f $_.Name, $_.InterfaceDescription, $_.Status, $_.LinkSpeed) }

Say "=== IP CONFIG ==="
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { Say ("  {0} on {1}" -f $_.IPAddress, $_.InterfaceAlias) }
Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object { if ($_.ServerAddresses) { Say ("  DNS via {0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', ')) } }

# The default route is the single most decisive fact: an adapter can show
# "Up" with an IP and still carry no internet. A 169.254.x.x address means
# DHCP never answered, and no default route means nothing is reachable
# regardless of what any adapter's status says.
Say "=== DEFAULT ROUTE (decides whether anything is reachable at all) ==="
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
if ($routes) { $routes | ForEach-Object { Say ("  via {0} gw={1} metric={2}" -f $_.InterfaceAlias, $_.NextHop, $_.RouteMetric) } }
else { Say "  *** NO DEFAULT ROUTE -- this sandbox has no internet path at all ***" }

# What Network List Manager thinks -- the exact source connectivity_plus
# reads on Windows. If this disagrees with the HTTPS test below, that is the
# false-negative the player's fail-open logic exists to survive.
Say "=== NETWORK LIST MANAGER (what connectivity_plus reads) ==="
try {
  $nlm = New-Object -ComObject 'NetworkListManager.NetworkListManager'
  Say "  IsConnectedToInternet = $($nlm.IsConnectedToInternet)"
  Say "  IsConnected           = $($nlm.IsConnected)"
} catch { Say "  NLM query FAILED: $_" }

Say "=== RUNTIME DEPENDENCIES ==="
$wv = ''
foreach ($k in @(
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
  'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
  if (Test-Path $k) { $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).pv; if ($v -and $v -ne '0.0.0.0') { $wv = $v } }
}
if ($wv) { Say "  WebView2 runtime: PRESENT ($wv)" } else { Say "  WebView2 runtime: MISSING (web-app content will not render; pairing still works)" }

Say "=== DNS RESOLUTION ==="
foreach ($h in @('signagexai.com','stage.signagexai.com')) {
  try { Say ("  {0} -> {1}" -f $h, ((Resolve-DnsName $h -Type A -ErrorAction Stop | Where-Object {$_.IPAddress}).IPAddress -join ', ')) }
  catch { Say "  $h -> RESOLVE FAILED: $($_.Exception.Message)" }
}

Say "=== HTTPS REACHABILITY (ground truth) ==="
try {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-WebRequest -Uri 'https://signagexai.com/v1/player-releases/latest?platform=windows' -UseBasicParsing -TimeoutSec 20
  $sw.Stop()
  Say ("  HTTP {0} in {1}ms" -f $r.StatusCode, $sw.ElapsedMilliseconds)
} catch { Say "  FAILED: $($_.Exception.Message)" }

Say "=== PAIRING ENDPOINT (what the Connecting screen blocks on) ==="
foreach ($apiHost in @('signagexai.com','stage.signagexai.com')) {
  try {
    $body = '{"platform":"windows","uuid":"sandbox-connectivity-probe"}'
    $r = Invoke-WebRequest -Uri "https://$apiHost/v1/player/connection/" -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20
    Say ("  POST $apiHost -> HTTP {0}" -f $r.StatusCode)
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { Say ("  POST $apiHost -> HTTP {0} (reachable)" -f [int]$resp.StatusCode) }
    else { Say "  POST $apiHost -> FAILED (no response): $($_.Exception.Message)" }
  }
}

Say "=== MQTT PORT 443 ==="
try {
  $t = Test-NetConnection -ComputerName 'signagexai.com' -Port 443 -WarningAction SilentlyContinue
  Say ("  TCP 443 reachable = {0}" -f $t.TcpTestSucceeded)
} catch { Say "  TCP 443 test FAILED: $_" }

# ---------- 4. build-identity verdict ----------
# A whole test cycle was burned running a stale installer left in the
# shared folder: the harness happily installs whatever .exe is there, and
# an old build fails exactly like a new one, so "still broken" looked
# identical to "you tested yesterday's binary". The app's own log settles
# it -- [Connectivity] lines only exist in builds carrying the connectivity
# diagnostics, and "network recovery" only in builds carrying the retry
# fix. Reported explicitly so nobody has to infer it from behaviour.
Say "=== BUILD IDENTITY (is this actually the build you meant to test?) ==="
if ($zip)            { Say ("  source: {0}  (built {1})" -f $zip.Name, $zip.LastWriteTime) }
elseif ($installer)  { Say ("  source: {0}  (built {1})" -f $installer.Name, $installer.LastWriteTime) }

$appLog = Join-Path $env:APPDATA 'SignageX\SignageX Player\signagex_debug.log'
Say "  waiting up to 90s for the player to write its log..."
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and -not (Test-Path $appLog)) { Start-Sleep -Seconds 3 }

if (-not (Test-Path $appLog)) {
  Say "  *** no debug log written at all -- the player never started, or crashed at launch ***"
} else {
  Start-Sleep -Seconds 20
  $content  = Get-Content $appLog -ErrorAction SilentlyContinue
  $hasConn  = ($content | Select-String -Pattern '\[Connectivity\]' -Quiet)
  $hasRetry = ($content | Select-String -Pattern 'network recovery|scheduling recovery retry' -Quiet)
  Say ("  connectivity diagnostics present : {0}" -f $(if ($hasConn)  {'YES'} else {'NO  <-- build predates a8e1b73'}))
  Say ("  retry fix present                : {0}" -f $(if ($hasRetry) {'YES (it fired)'} else {'not observed -- either absent, or the first connect succeeded'}))
  if (-not $hasConn) {
    Say "  *** STALE BUILD -- replace the file in the shared folder with the"
    Say "      latest artifact and rerun. Results below this line mean nothing. ***"
  }
  Say "  --- connectivity / connection lines from the player ---"
  $content | Select-String -Pattern '\[Connectivity\]|_mqttConnection|network recovery|state ->' |
    Select-Object -Last 30 | ForEach-Object { Say ("    " + $_.Line) }
}

Say "=== DIAGNOSTICS COMPLETE -- logs continue mirroring to C:\share\logs ==="

# Keep the harness process alive so the window stays available; the mirror
# runs independently in its own process regardless.
while ($true) { Start-Sleep -Seconds 30 }
