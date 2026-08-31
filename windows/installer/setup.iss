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
ArchitecturesInstallIn64BitMode=x64
; Without this, if the app is already running (e.g. re-running the installer
; to update, or installing production over a staging test build), Windows
; keeps flutter_windows.dll/icudtl.dat locked and Inno Setup silently skips
; overwriting them -- leaving a stale engine DLL next to a newer app.so,
; which makes the app open a permanently blank grey window (engine/AOT
; snapshot version mismatch, never renders a frame). CloseApplications uses
; the Restart Manager to detect and close the running app before copying;
; RestartApplications relaunches it after install finishes.
CloseApplications=yes
RestartApplications=yes
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

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent
