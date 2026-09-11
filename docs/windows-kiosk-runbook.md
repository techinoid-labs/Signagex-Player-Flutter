# Windows signage pilot and kiosk setup

## Scope and status

Target x64 Windows 11 Pro, Windows 11 IoT Enterprise LTSC 2024, and Windows 10
IoT Enterprise LTSC 2021. Installation eligibility is not certification. Record
the exact OS build, GPU/driver, display, installer build ID and results for each
box. ARM emulation is not certified by this work.

This change adds a process-crash supervisor and an application keep-awake request.
It does not detect a frozen renderer, a stalled video, a dead supervisor, or a
network outage. It does not install a service, change passwords/power plans,
configure auto-login, or modify firmware. Those device settings below must be
applied by the provisioning team.

## Installed behavior

- Start Menu, desktop and sign-in startup shortcuts launch `SignageXWatchdog.exe`.
  It starts `SignageXPlayer.exe` from its own installation directory.
- Normal player exit (including Alt+F4/window close) stops supervision. Escape
  still changes fullscreen mode; it is not an exit command.
- A nonzero exit restarts after 5, 10, 20, 40, then 80 seconds. After five retries
  without a ten-minute stable run, supervision stops. Diagnose the failure and
  launch the shortcut again to reset the budget. A nonzero forced termination
  is treated as a crash; use `--stop` for maintenance instead.
- The supervisor receives Windows session-end messages and does not relaunch
  during sign-out/shutdown. Shutdown cancellation can leave supervision stopped;
  relaunch the shortcut if the session remains open.
- Only one supervisor and one player run per installation path in a Windows
  session. Separate sessions have separate instances. Directly launching the
  player bypasses supervision; use the installed shortcut for unattended use.
- `watchdog.log` is written beside the launcher. Above 1 MiB it rotates to
  `watchdog.log.previous`. An unwritable portable directory can prevent logging;
  the normal per-user installer directory is writable.
- The player requests system/display wakefulness for its lifetime and clears
  the request on normal exit. Windows removes thread requests on process exit.
  This prevents idle sleep/display timeout; it does not override explicit sleep,
  lock-screen policy, screensavers, monitor firmware timers or power failure.

Microsoft reference: [SetThreadExecutionState](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate).

## Prepare one clean pilot box

1. Provision a dedicated standard Windows account for signage. Keep a separate
   administrator maintenance account and a tested way to recover the device.
2. Install as the signage user; this is a per-user installation. Leave
   **Launch automatically when Windows starts** enabled. It means at that user's
   sign-in, not before anyone logs in.
3. Configure automatic sign-in using your organization's approved method or the
   [Microsoft Autologon guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon).
   Prefer the Sysinternals UI over a script containing a password. Do not place
   credentials in this repository or use an administrator account for signage.
4. Decide whether the device needs OS lockdown. Fullscreen and a hidden taskbar
   are not security boundaries. On Enterprise/IoT editions, assess
   [Shell Launcher](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/commercialization/iot-ent-shell-launcher-app-launcher).
   Configure the supervisor as the shell if used, and avoid an independent shell
   restart policy that defeats its crash limit or maintenance stop. Shell
   Launcher is a separate rollout requiring its own escape/recovery procedure.
5. Capture current power settings with `powercfg /query`. On a dedicated,
   mains-powered pilot, the provisioning administrator may apply the following
   to the active plan. Record the original values for rollback:

   ```powershell
   powercfg /change monitor-timeout-ac 0
   powercfg /change standby-timeout-ac 0
   powercfg /change hibernate-timeout-ac 0
   ```

   These are optional device policy changes, not commands run by the installer.
   Keep battery policies intentional. Check screensaver, session-lock and domain
   policies separately. [Powercfg reference](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options).
6. In BIOS/UEFI, configure the vendor's **Restore AC power / Power on after power
   loss** option. Configure the signage display's own power-on/input selection
   and eco timers. `powercfg` cannot configure firmware or start a powerless box.
7. Install a tested graphics driver and confirm the intended resolution,
   orientation, audio output, time zone and clock synchronization.

## Offline provisioning

Set the repository variable `WEBVIEW2_INSTALLER_URL` to an approved x64 Evergreen
Standalone Installer URL before building the offline artifact. The default URL
is an online bootstrapper. Test with WebView2 absent and the network disconnected.
Successful setup alone is insufficient: open a campaign using embedded HTML/web
content after installation. Remote websites still need connectivity even though
WebView2 installed offline.

## Maintenance, upgrade, and uninstall

Use the installed directory (production example):

```powershell
$playerDirectory = Join-Path $env:LOCALAPPDATA 'SignageX Player'
$stop = Start-Process (Join-Path $playerDirectory 'SignageXWatchdog.exe') -ArgumentList '--stop' -Wait -PassThru
$stop.ExitCode
```

Exit zero means the supervisor stopped and its player exited. A nonzero result
means a hung/directly launched player or another error needs operator attention.
The supervisor requests a graceful close and waits up to ten seconds; it never
force-kills a hung application. Inspect Task Manager and the log before retrying.

Setup and uninstall call this stop command themselves. Setup aborts preparation
if it cannot stop safely. Do not reopen shortcuts during installation. Windows
Restart Manager still handles files held by older/directly launched versions;
automatic Restart Manager relaunch is disabled so the installer starts the
supervisor rather than an unsupervised player.

- Interactive setup offers its usual launch checkbox, now pointing at the supervisor.
- Silent upgrades restart the supervised player by default, including updates
  initiated by an older player. `/RESTARTPLAYER=0` suppresses that restart.
- Fresh silent installations do not launch unless `/RESTARTPLAYER=1` is supplied.
- The updated in-app updater explicitly passes `/RESTARTPLAYER=1`.
- If setup is canceled or fails after supervision stops, finish maintenance and
  restart the installed shortcut manually. Do not start an installer concurrently
  from multiple sessions. If Windows reports a required restart, reboot and
  validate the final installed version before accepting the upgrade.
- Uninstall stops supervision and removes installed shortcuts. Logs may remain
  in the application directory for diagnosis; remove them manually if desired.

For a portable ZIP, launch the watchdog beside the player. There is no automatic
startup registration for a ZIP. Stop supervision before replacing ZIP contents.

## Acceptance gates

Run this sequence first on Windows 11 Pro, then repeat on both IoT/LTSC targets.
Record observed results rather than marking a check passed because code exists.

| Check | Required result |
|---|---|
| Clean online/offline install | Runtime dependencies install; player and WebView content render |
| Unsupported OS/architecture | Installer refuses devices outside the configured policy |
| Pair and publish | Correct device code, current campaign, zone geometry and audio |
| Long mixed playback | Video/images/web/nested compositions cycle without freezes or leaks |
| Idle display | `powercfg /requests` shows the player request; screen stays on past idle timeout |
| Exit cleanup | Close player normally; no relaunch and no remaining player wake request |
| Crash recovery | On a disposable pilot, terminate only the player's PID with a nonzero exit; exactly one replacement starts after backoff |
| Duplicate shortcut | Opening twice never creates a second player or supervisor |
| Crash loop | Native policy test verifies cap; on-box repeated failure stops after five retries |
| Maintenance stop | `--stop` exits supervisor and player, with no relaunch |
| Hung player | No forced termination; stop/update reports failure and operator resolves it |
| Network loss | Cached media continues; reconnect does not restore old content |
| Reboot/sign-out | No shutdown-relaunch race; after configured sign-in one supervisor/player starts |
| Power loss | Controlled pilot power cycle returns through firmware boot, login and cached playback |
| Upgrade while running | Supervisor stops, files replace, one supervised player returns with the new build |
| Older-version upgrade | Old updater without restart flag still returns to supervised playback |
| Upgrade cancellation | No retry storm; operator can relaunch the remaining installation |
| Uninstall while running | No relaunch, no running installed processes, startup shortcut removed |

## Verification available in this change

`windows/tests/watchdog_policy_test.cpp` is portable and checks clean exits,
backoff, retry exhaustion and stable-run reset. It was compiled and passed on
the authoring Mac. `windows-kiosk-tests.yml` compiles the native supervisor and
a fake player on Windows, tests real process recovery/maintenance, and compiles
the installer script using test binaries. That workflow is added, not yet run
in this authoring session. Its installer is a test artifact, never a release.

The Flutter release build, real installer upgrade/uninstall, keep-awake behavior,
sign-out handling and hardware acceptance remain pending on Windows. No OS
settings were changed on the authoring machine. Watchdog hang detection, external
DDC/CI brightness and the existing product gaps are separate follow-ups.
