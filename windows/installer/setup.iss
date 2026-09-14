; SignageX Player -- Windows installer (Inno Setup)
;
; Produces a single setup.exe that installs the app, creates Start Menu/
; desktop shortcuts, and optionally registers it to launch automatically
; on Windows sign-in (a kiosk/signage player is meant to run unattended).
; PrivilegesRequired=lowest + a per-user DefaultDirName means this never
; needs admin rights or a UAC prompt -- important for provisioning kiosk
; machines under a limited/dedicated account, and for scripted/silent
; installs (see below).
;
; Build locally:
;   iscc windows\installer\setup.iss
; (defaults to the production build already sitting in
; build\windows\x64\runner\Release -- override via /DSourceDir=,
; /DAppSuffix=, /DOutputBaseFilename= for a staging build; see
; .github\workflows\build-windows.yml for the exact invocation used in CI)
;
; Silent/unattended install (once you have the compiled setup.exe):
;   SignageX-Player-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
; Add /TASKS="startupicon" to also enable launch-at-startup silently, or
; /TASKS="!startupicon" to explicitly skip it (it's on by default).

#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef AppSuffix
  #define AppSuffix ""
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "SignageX-Player-Setup"
#endif

#define MyAppName "SignageX Player" + AppSuffix
#define MyAppVersion "1.0.0"
#define MyAppPublisher "SignageX"
#define MyAppExeName "SignageXPlayer.exe"
#define MyLauncherExeName "SignageXWatchdog.exe"

[Setup]
; Fixed AppId so re-running the installer (same or newer version) upgrades
; the existing install in place instead of creating a side-by-side copy --
; do not change this once installers have shipped.
AppId={{B9C1F2B1-6B2E-4C0B-9C7B-2F6E6E1D6B21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
; Refuse to install on unsupported Windows, up front with a clear message,
; instead of installing and then failing at runtime. Both the Flutter Windows
; engine and WebView2 (the in-app browser) require Windows 10 version 1809
; (build 17763) or newer -- older Windows 10 and Windows 7/8/8.1 are out.
MinVersion=10.0.17763
; The app is x64 only (there is no 32-bit Flutter Windows build). x64compatible
; allows native x64 Windows AND ARM64 devices running x64 under emulation, while
; blocking 32-bit-only Windows where the app cannot run. (Requires Inno Setup
; 6.3+, which CI's chocolatey innosetup provides.)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Without this, if the app is already running (e.g. re-running the installer
; to update, or installing production over a staging test build), Windows
; keeps flutter_windows.dll/icudtl.dat locked and Inno Setup silently skips
; overwriting them -- leaving a stale engine DLL next to a newer app.so,
; which makes the app open a permanently blank grey window (engine/AOT
; snapshot version mismatch, never renders a frame). CloseApplications uses
; the Restart Manager to detect and close the running app before copying;
; the supervised launcher is started explicitly after installation.
CloseApplications=yes
; Relaunch through our supervisor explicitly, never just the child process.
RestartApplications=no
OutputDir=..\..\dist
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startupicon"; Description: "Launch {#MyAppName} automatically when Windows starts (recommended for signage displays)"; GroupDescription: "Additional options:"; Flags: checkedonce
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional options:"; Flags: unchecked

[Files]
; restartreplace: belt-and-suspenders fallback if CloseApplications above
; still can't free a locked file (e.g. a second copy running under another
; user session) -- Windows finishes the replace on next reboot instead of
; silently leaving the old file in place.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion restartreplace recursesubdirs createallsubdirs
; Microsoft Edge WebView2 runtime installer. The in-app webview
; (flutter_inappwebview) needs the WebView2 runtime; a fresh Windows box may
; not have it, and the plugin DLL then fails to load at launch with a "Bad
; Image" error. CI downloads this next to setup.iss before compiling -- either
; the small online Evergreen bootstrapper (default) or, for offline/kiosk
; builds, a pinned Evergreen Standalone Installer (see build-windows.yml,
; WEBVIEW2_INSTALLER_URL); both are driven identically below. The filename is
; kept constant so this line doesn't care which one it is.
; skipifsourcedoesntexist keeps a plain local `iscc` working when it hasn't
; been fetched. (The Visual C++ runtime DLLs the plugin also needs are copied
; app-local into {#SourceDir} by CI, so they arrive via the line above.)
Source: "MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist

[UninstallDelete]
; W01: Inno Setup's uninstaller only removes files it tracked installing
; from [Files] above -- anything the running app writes afterward is
; invisible to it. An earlier version of this section force-deleted the
; entire {app} tree (`filesandordirs` on "{app}"), which is unsafe:
; installation-directory selection isn't restricted to a directory newly
; created and exclusively owned by this app (Inno Setup's own docs warn
; against exactly this -- see jrsoftware.org/ishelp/topic_uninstalldeletesection.htm),
; so a custom install location containing unrelated files would have had
; them deleted too. Only the two specific, known runtime-created locations
; are targeted by name now, and {app} itself is removed only if that
; leaves it empty -- unrelated files anywhere under a custom {app} survive.
;
; WebView2's own cache/cookies/IndexedDB storage. The name below was
; WRONG and the deletion therefore never matched anything: verified on a
; real install, the actual path is
;   {app}\SignageXPlayer.exe.WebView2\EBWebView
; When no custom user-data folder is configured, WebView2 defaults the UDF
; to "<exe-name>.WebView2" next to the exe and creates EBWebView INSIDE
; that -- so "{app}\EBWebView" is one level too high. (EBWebView is only
; the top-level name when an app explicitly passes its own UDF.)
;
; Consequence was not cosmetic: because that folder survived, the
; "dirifempty" on {app} below could never succeed either, so EVERY
; uninstall/upgrade orphaned its entire install directory. Measured on the
; test machine: five leftover SignageX Player-* folders totalling 263 MB,
; none of which any uninstall had been able to remove. On a kiosk that
; auto-updates unattended for months this grows without bound -- and a
; full disk on a signage box is an outage, not an inconvenience.
;
; Uses the exe-name define rather than a hardcoded string so renaming the
; exe can't silently reintroduce the same mismatch.
Type: filesandordirs; Name: "{app}\{#MyAppExeName}.WebView2"
; Kept as a harmless fallback in case a future build sets an explicit
; user-data folder, which would put EBWebView directly under {app}.
Type: filesandordirs; Name: "{app}\EBWebView"
; The watchdog writes its own rotating log into the install directory
; (windows/runner/watchdog_main.cpp's Log(), which rotates to
; watchdog.log.previous at 1 MB). Both are created at RUNTIME, so [Files]
; does not track them and they too would keep {app} non-empty forever --
; the leftover "SignageX Player-99" on the test machine contained nothing
; but the WebView2 folder and exactly this log.
Type: files; Name: "{app}\watchdog.log"
Type: files; Name: "{app}\watchdog.log.previous"
; Same reasoning -- the post-install WebView2 check (CurStepChanged)
; writes this at runtime, so it is untracked by [Files] too.
Type: files; Name: "{app}\WEBVIEW2-MISSING.txt"
; Written at runtime by the watchdog after an abnormal exit, so the
; next player run can upload that run's log. Untracked by [Files] for
; the same reason as the logs above.
Type: files; Name: "{app}\crash-marker.txt"
; shared_preferences_windows and the debug log (lib/utils/debug_log.dart)
; both resolve their storage directory from the same CompanyName/
; ProductName pair in windows/runner/Runner.rc, which lands them both
; under %AppData%\SignageX\SignageX Player -- NOT under {app} at all.
; This holds pairing state, the cached campaign JSON, and the debug log.
Type: filesandordirs; Name: "{userappdata}\SignageX\SignageX Player"
; Only removes {app} if the two deletions above (plus [Files]'s own
; tracked removal) left it empty -- never touches a non-empty directory,
; so unrelated files in a custom install location are preserved.
Type: dirifempty; Name: "{app}"

[Icons]
; IconFilename points every shortcut at the PLAYER's icon even though the
; shortcut launches the watchdog. The watchdog now carries the icon itself
; (windows/runner/watchdog.rc), but stating it here too means shortcuts are
; branded correctly even where the watchdog predates that, and it makes the
; intent explicit rather than dependent on which exe happens to be launcher.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
; Ensure the Edge WebView2 runtime is present before first launch -- per-user,
; silent, no admin (matches PrivilegesRequired=lowest). Skipped when already
; installed or when the bootstrapper wasn't bundled (see NeedsWebView2).
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 runtime (required for playback)..."; Flags: waituntilterminated; Check: NeedsWebView2
Filename: "{app}\{#MyLauncherExeName}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent

; Silent upgrades restart by default, including older in-app updaters that do
; not yet pass /RESTARTPLAYER. Fresh silent installs need /RESTARTPLAYER=1.
Filename: "{app}\{#MyLauncherExeName}"; Flags: nowait; Check: RestartPlayerSilently

[Code]
var
  UpgradingPlayer: Boolean;

function RestartPlayerSilently(): Boolean;
var
  DefaultRestart: String;
begin
  DefaultRestart := '0';
  if UpgradingPlayer then DefaultRestart := '1';
  Result := WizardSilent and
    (ExpandConstant('{param:RESTARTPLAYER|' + DefaultRestart + '}') = '1');
end;

function StopPlayerSupervisor(): Boolean;
var
  ExitCode: Integer;
  Launcher: String;
begin
  Launcher := ExpandConstant('{app}\{#MyLauncherExeName}');
  Result := True;
  if FileExists(Launcher) then
    Result := Exec(Launcher, '--stop', ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  UpgradingPlayer := FileExists(ExpandConstant('{app}\{#MyAppExeName}'));
  Result := '';
  if not StopPlayerSupervisor() then
    Result := 'Close SignageX Player and its watchdog, then retry installation.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := StopPlayerSupervisor();
  if not Result then
    MsgBox('Close SignageX Player and its watchdog, then retry uninstall.', mbError, MB_OK);
end;

{ True when the Edge WebView2 Evergreen runtime is NOT installed, so the bundled
  bootstrapper should run. Detects the Evergreen client under EdgeUpdate
  (per-machine on 64-bit Windows, else per-user); a missing/empty/"0.0.0.0"
  version means absent. Returns False (nothing to do) if the bootstrapper file
  wasn't bundled into this build. }
function WebView2Version(): String;
var
  pv: String;
begin
  pv := '';
  RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', pv);
  if pv = '' then
    RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', pv);
  if pv = '0.0.0.0' then
    pv := '';
  Result := pv;
end;

function NeedsWebView2(): Boolean;
begin
  if not FileExists(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe')) then
  begin
    Result := False;
    exit;
  end;
  Result := (WebView2Version() = '');
end;

{ Verifies AFTER install that the WebView2 runtime is actually present.
  The [Run] entry above cannot do this: Inno ignores a [Run] program's exit
  code, so a FAILED WebView2 install let setup report success and produced
  an installation that dies at launch with

    SignageXPlayer.exe - Bad Image
    ...flutter_inappwebview_windows_plugin.dll is either not designed to
    run on Windows or it contains an error. Error status 0xc0e90002.

  which is precisely the failure reported from a customer site. The plugin
  DLL is loaded during Flutter's plugin registration at startup, so this is
  not a degraded mode -- the app cannot start at all.

  The default bundled bootstrapper (~2 MB) DOWNLOADS the runtime at install
  time, so it fails on exactly the machines most likely to be kiosks:
  offline, captive-portal, or firewall-restricted. Rather than let that
  surface hours later as an unexplained crash loop, fail loudly here and
  leave a marker file naming the fix. For genuinely offline fleets, set the
  WEBVIEW2_INSTALLER_URL repo variable to the pinned Evergreen STANDALONE
  installer so no download is needed -- see .github/workflows/build-windows.yml. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  Marker: String;
  Msg: String;
begin
  if CurStep <> ssPostInstall then
    exit;
  Marker := ExpandConstant('{app}\WEBVIEW2-MISSING.txt');
  if WebView2Version() = '' then
  begin
    Msg := 'The Microsoft Edge WebView2 runtime is not installed, and this' + #13#10 +
           'installer could not install it (it is downloaded at install time,' + #13#10 +
           'so this usually means no internet access during setup).' + #13#10#13#10 +
           'SignageX Player CANNOT START without it -- it will fail with a' + #13#10 +
           '"Bad Image" error naming flutter_inappwebview_windows_plugin.dll.' + #13#10#13#10 +
           'Install the WebView2 Evergreen Runtime on this machine, then' + #13#10 +
           'launch the player again.';
    { Written unconditionally: a silent/unattended install (how fleet
      deployments run) suppresses the dialog entirely, so the marker file is
      the only trace whoever investigates later will have. }
    SaveStringToFile(Marker, Msg, False);
    if not WizardSilent() then
      MsgBox(Msg, mbError, MB_OK);
  end
  else
    { Clear a marker left by an earlier broken install once it is fixed. }
    DeleteFile(Marker);
end;
