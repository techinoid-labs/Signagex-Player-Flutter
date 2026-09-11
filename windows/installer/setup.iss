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
; Inno Setup's uninstaller only removes files it tracked installing from
; [Files] above -- anything the running app writes afterward into its own
; install folder (shared_preferences.json holding pairing state/cached
; campaign JSON, WebView2's own EBWebView cache/cookies/IndexedDB folder,
; which defaults to living next to the exe when no custom user-data
; folder is configured) is invisible to it, so {app} never ends up empty
; and never actually gets removed on its own. Force-deleting the whole
; tree here means uninstall actually leaves nothing behind, and a
; reinstall always starts from a genuinely clean/unpaired state.
Type: filesandordirs; Name: "{app}"
; The debug log (lib/utils/debug_log.dart) lives in a completely separate
; directory tree that [Files] never manages at all.
Type: filesandordirs; Name: "{userappdata}\SignageX\SignageX Player"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyLauncherExeName}"; Tasks: startupicon

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
function NeedsWebView2(): Boolean;
var
  pv: String;
begin
  if not FileExists(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe')) then
  begin
    Result := False;
    exit;
  end;
  pv := '';
  RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', pv);
  if pv = '' then
    RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', pv);
  Result := (pv = '') or (pv = '0.0.0.0');
end;
