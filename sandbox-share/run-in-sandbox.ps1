# Runs automatically inside Windows Sandbox (see signagex-sandbox.wsb).
#
# Windows Sandbox is isolated and ephemeral -- its filesystem isn't visible
# from the host and everything is destroyed on close, which is why the
# player's debug log has been unreadable for every sandbox test so far.
# C:\share is mapped read-write to a real host folder, so anything written
# there IS readable from the host while the sandbox is still running.
#
# Does three things, in order:
#   1. Network self-test, BEFORE the app starts -- separates "the sandbox
#      itself can't reach the backend" from "the app can't, but the sandbox
#      can". Those are completely different problems and the app's own logs
#      can't tell them apart.
#   2. Installs whatever SignageX installer .exe is in C:\share.
#   3. Continuously mirrors both log files out to C:\share\logs.

$ErrorActionPreference = 'Continue'
$share = 'C:\share'
$diag  = Join-Path $share 'sandbox-diag.txt'
$logs  = Join-Path $share 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Say($msg) {
  $line = "$(Get-Date -Format 'HH:mm:ss')  $msg"
  Add-Content -Path $diag -Value $line -Encoding utf8
}

Set-Content -Path $diag -Value "SignageX sandbox diagnostics - $(Get-Date)" -Encoding utf8

# ---------- 1. network self-test ----------
Say "=== TIME / TIMEZONE ==="
Say "local=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')  tz=$((Get-TimeZone).Id)"

Say "=== ADAPTERS ==="
Get-NetAdapter | ForEach-Object { Say ("  {0} | {1} | status={2} | speed={3}" -f $_.Name, $_.InterfaceDescription, $_.Status, $_.LinkSpeed) }

Say "=== IP CONFIG ==="
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { Say ("  {0} on {1}" -f $_.IPAddress, $_.InterfaceAlias) }
Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object { if ($_.ServerAddresses) { Say ("  DNS via {0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', ')) } }

# What Network List Manager thinks -- this is the exact source
# connectivity_plus reads on Windows, and the thing suspected of being
# wrong on Hyper-V/virtual NICs. If this says "no internet" while the
# HTTPS test below succeeds, that confirms the false-negative directly.
Say "=== NETWORK LIST MANAGER (what connectivity_plus reads) ==="
try {
  $nlm = New-Object -ComObject 'NetworkListManager.NetworkListManager'
  Say "  IsConnectedToInternet = $($nlm.IsConnectedToInternet)"
  Say "  IsConnected           = $($nlm.IsConnected)"
  foreach ($n in $nlm.GetNetworks(1)) {
    Say ("  network '{0}': connected={1} connectivity={2}" -f $n.GetName(), $n.IsConnected, $n.GetConnectivity())
  }
} catch { Say "  NLM query FAILED: $_" }

Say "=== DNS RESOLUTION ==="
foreach ($h in @('signagexai.com','stage.signagexai.com','norwin.sfo3.digitaloceanspaces.com')) {
  try { Say ("  {0} -> {1}" -f $h, ((Resolve-DnsName $h -Type A -ErrorAction Stop | Where-Object {$_.IPAddress}).IPAddress -join ', ')) }
  catch { Say "  $h -> RESOLVE FAILED: $($_.Exception.Message)" }
}

Say "=== HTTPS REACHABILITY (the real ground truth) ==="
foreach ($u in @('https://signagexai.com/v1/player-releases/latest?platform=windows')) {
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20
    $sw.Stop()
    Say ("  {0} -> HTTP {1} in {2}ms, {3} bytes" -f $u, $r.StatusCode, $sw.ElapsedMilliseconds, $r.Content.Length)
  } catch { Say "  $u -> FAILED: $($_.Exception.Message)" }
}

# The pairing endpoint the player actually calls when it shows
# "Connecting..." -- a 4xx here is FINE (means reachable, just unpaired);
# a timeout/DNS/TLS error is the actual failure we're hunting.
# Both hosts are checked because a production build talks to
# signagexai.com and a staging build talks to stage.signagexai.com, and
# the release feed has been observed serving the staging installer from
# the production URL -- so "which host does this build even use" can't be
# assumed.
Say "=== PAIRING ENDPOINT (what the Connecting screen is blocked on) ==="
# NB: not $host -- that's a read-only PowerShell automatic variable and
# assigning it in a foreach throws.
foreach ($apiHost in @('signagexai.com','stage.signagexai.com')) {
  try {
    $body = '{"platform":"windows","uuid":"sandbox-connectivity-probe"}'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri "https://$apiHost/v1/player/connection/" -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20
    $sw.Stop()
    Say ("  POST $apiHost/v1/player/connection/ -> HTTP {0} in {1}ms" -f $r.StatusCode, $sw.ElapsedMilliseconds)
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { Say ("  POST $apiHost/v1/player/connection/ -> HTTP {0} (reachable; non-2xx is fine here)" -f [int]$resp.StatusCode) }
    else { Say "  POST $apiHost/v1/player/connection/ -> FAILED (no response): $($_.Exception.Message)" }
  }
}

Say "=== MQTT PORT (wss://signagexai.com:443/mqtt) ==="
try {
  $t = Test-NetConnection -ComputerName 'signagexai.com' -Port 443 -WarningAction SilentlyContinue
  Say ("  TCP 443 reachable = {0} (latency {1}ms)" -f $t.TcpTestSucceeded, $t.PingReplyDetails.RoundtripTime)
} catch { Say "  TCP 443 test FAILED: $_" }

# ---------- 1b. runtime dependencies ----------
# A customer site hit:
#   SignageXPlayer.exe - Bad Image
#   flutter_inappwebview_windows_plugin.dll is either not designed to run on
#   Windows or it contains an error. Error status 0xc0e90002.
# That is a DLL load/init failure, and the app dies at STARTUP because the
# plugin DLL is loaded during Flutter's plugin registration -- not a
# degraded mode. The two things that cause it are a missing Edge WebView2
# runtime and a missing MSVC runtime, so check both explicitly BEFORE the
# install rather than inferring it from a crash later.
#
# Windows Sandbox is the interesting case precisely because it is a clean,
# ephemeral image: it is a good proxy for a freshly-imaged kiosk, which is
# where this failure actually shows up.
Say "=== RUNTIME DEPENDENCIES (cause of the 'Bad Image' failure) ==="

$wv = ''
foreach ($k in @(
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
  'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
  if (Test-Path $k) { $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).pv; if ($v -and $v -ne '0.0.0.0') { $wv = $v } }
}
if ($wv) { Say "  WebView2 Evergreen runtime: PRESENT (version $wv)" }
else     { Say "  WebView2 Evergreen runtime: *** MISSING *** -- installer must supply it" }

# The VC++ runtime is shipped app-local (CI copies the CRT redist next to
# the exe), so a machine-wide redist is NOT required. Reported anyway to
# tell the two situations apart if a Bad Image ever recurs.
$sysCrt = Test-Path (Join-Path $env:SystemRoot 'System32\vcruntime140.dll')
Say "  machine-wide VC++ runtime (System32\vcruntime140.dll): $(if ($sysCrt) {'present'} else {'absent -- fine, app ships its own'})"

# ---------- 2. install ----------
$installer = Get-ChildItem -Path $share -Filter '*.exe' | Where-Object { $_.Name -like '*Setup*' -or $_.Name -like '*SignageX*' } | Select-Object -First 1
if ($installer) {
  Say "=== INSTALLING $($installer.Name) ==="
  $p = Start-Process -FilePath $installer.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/RESTARTPLAYER=1' -PassThru -Wait
  Say "  installer exited with $($p.ExitCode)"

  # Confirms the shipped payload is complete -- an installer can exit 0 and
  # still leave the app unable to start if these are absent.
  $appDir = Get-ChildItem "$env:LOCALAPPDATA" -Directory -Filter 'SignageX*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1
  if ($appDir) {
    Say "  installed to: $($appDir.FullName)"
    foreach ($dll in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll',
                       'WebView2Loader.dll','flutter_inappwebview_windows_plugin.dll',
                       'flutter_windows.dll')) {
      $present = Test-Path (Join-Path $appDir.FullName $dll)
      Say ("    {0,-45} {1}" -f $dll, $(if ($present) {'ok'} else {'*** MISSING ***'}))
    }
    if (Test-Path (Join-Path $appDir.FullName 'WEBVIEW2-MISSING.txt')) {
      Say "    *** installer flagged WEBVIEW2-MISSING.txt -- app will not start ***"
    }
  } else {
    Say "  could not locate the installed app directory"
  }
} else {
  Say "=== NO INSTALLER FOUND in C:\share -- put the Setup .exe there ==="
}

# ---------- 3. mirror logs out to the host ----------
Say "=== MIRRORING LOGS to C:\share\logs (updates every 3s) ==="
$appLog = Join-Path $env:APPDATA 'SignageX\SignageX Player\signagex_debug.log'
while ($true) {
  try {
    if (Test-Path $appLog) { Copy-Item $appLog (Join-Path $logs 'signagex_debug.log') -Force -ErrorAction SilentlyContinue }
    Get-ChildItem 'C:\Users\WDAGUtilityAccount\AppData\Local' -Filter 'SignageX*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $w = Join-Path $_.FullName 'watchdog.log'
      if (Test-Path $w) { Copy-Item $w (Join-Path $logs "watchdog-$($_.Name).log") -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
  Start-Sleep -Seconds 3
}
