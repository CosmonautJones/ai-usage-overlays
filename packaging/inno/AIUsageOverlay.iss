#define AppName "AI Usage Overlay"
#ifndef AppVersion
#define AppVersion "0.1.0"
#endif
#ifndef RepoRoot
#define RepoRoot "..\.."
#endif
#ifndef OutputDir
#define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{C88512A1-AC3D-4D85-9B96-ACDFD9439AF3}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=AI Usage Overlay
AppPublisherURL=https://github.com/CosmonautJones/ai-usage-overlays
AppSupportURL=https://github.com/CosmonautJones/ai-usage-overlays/issues
AppUpdatesURL=https://github.com/CosmonautJones/ai-usage-overlays/releases
DefaultDirName={localappdata}\AIUsageOverlay
DefaultGroupName=AI Usage Overlay
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=AIUsageOverlaySetup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=AI Usage Overlay
UninstallDisplayIcon={sys}\wscript.exe
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#RepoRoot}\unified-overlay.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\Start-Unified.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\sqlite3.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\docs\preview.png"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "{#RepoRoot}\packaging\build\app-version.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#RepoRoot}\src\*.ps1"; DestDir: "{app}\src"; Flags: ignoreversion
Source: "{#RepoRoot}\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "{#RepoRoot}\packaging\inno\installer-hooks.ps1"; DestDir: "{app}\packaging"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\AI Usage Overlay"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Start-Unified.vbs"""; WorkingDir: "{app}"
Name: "{autoprograms}\Uninstall AI Usage Overlay"; Filename: "{uninstallexe}"

[Run]
Filename: "{code:GetPowerShellPath}"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\packaging\installer-hooks.ps1"" -Action Install -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; StatusMsg: "Starting AI Usage Overlay..."

[UninstallRun]
Filename: "{code:GetPowerShellPath}"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\packaging\installer-hooks.ps1"" -Action Uninstall -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "StopAIUsageOverlay"

[Code]
function GetPowerShellPath(Param: String): String;
var
  Candidate: String;
begin
  Candidate := ExpandConstant('{pf}\PowerShell\7\pwsh.exe');
  if FileExists(Candidate) then
  begin
    Result := Candidate;
    exit;
  end;

  Candidate := ExpandConstant('{pf32}\PowerShell\7\pwsh.exe');
  if FileExists(Candidate) then
  begin
    Result := Candidate;
    exit;
  end;

  Candidate := ExpandConstant('{localappdata}\Microsoft\WindowsApps\pwsh.exe');
  if FileExists(Candidate) then
  begin
    Result := Candidate;
    exit;
  end;

  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(
    GetPowerShellPath(''),
    '-NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 5) { exit 1 }"',
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode);

  if (not Result) or (ResultCode <> 0) then
  begin
    MsgBox('AI Usage Overlay requires Windows PowerShell 5.1 or PowerShell 7+.', mbCriticalError, MB_OK);
    Result := False;
  end;
end;
