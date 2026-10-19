; NV-AI for Windows - setup for a freshly installed PC.
; Built by build-setup.ps1, which assembles build\stage and passes AppVersion, StageDir and
; WithAddon. Installs per user, without admin rights. English by default, German on German
; Windows (Inno picks the language from the Windows UI language).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "build\stage"
#endif
; /D defines arrive as text ("0" would otherwise count as true) - hence the string compare.
#ifndef WithAddon
  #define WithAddon "0"
#endif
; Minimum driver for PyTorch cu130: branch R580 (comfy-kitchen: "Driver r580+"); the first
; Windows driver of that branch was 580.88. Since CUDA 13 NVIDIA no longer lists a Windows number.
#define PhotoCraftUrl "https://github.com/storytold/photocraft/releases/latest"
#ifndef MinDriverMajor
  #define MinDriverMajor 580
#endif
#ifndef MinDriverMinor
  #define MinDriverMinor 88
#endif

[Setup]
AppId={{8C1F0E4A-5B7D-4E8A-9C2B-6A1D3F5E7B90}
AppName=NV-AI
AppVersion={#AppVersion}
AppVerName=NV-AI {#AppVersion}
AppPublisher=NVAI-open
AppPublisherURL=https://github.com/Mantux775/NVAI-open
AppSupportURL=https://github.com/Mantux775/NVAI-open/issues
DefaultDirName={localappdata}\Programs\NV-AI
DefaultGroupName=NV-AI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir=build
OutputBaseFilename=NV-AI-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=NV-AI
SetupIconFile={#StageDir}\app\nvai.ico
UninstallDisplayIcon={app}\nvai.ico
CloseApplications=no
ShowLanguageDialog=auto
; Inno 6.5+ enables Windows' RedirectionGuard and every child process inherits it. uv then
; fails on its own Python junction ("untrusted mount point", os error 448 - measured). The
; protection targets elevated installers; this setup runs per user without admin rights.
RedirectionGuard=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"; InfoBeforeFile: "GETTING_STARTED.txt"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"; InfoBeforeFile: "ERSTE_SCHRITTE.txt"

[CustomMessages]
en.TypeFull=Full installation
de.TypeFull=Vollständige Installation
en.TypeBasic=NV-AI only (images, audio, video)
de.TypeBasic=Nur NV-AI (Bilder, Audio, Video)
en.Comp3D=3D: TripoSG - turn images into 3D meshes (the model itself, 7.4 GB, is downloaded in NV-AI)
de.Comp3D=3D: TripoSG – Bilder zu 3D-Modellen (das Modell selbst, 7,4 GB, lädt NV-AI bei Bedarf)
en.TypeCustom=Custom
de.TypeCustom=Benutzerdefiniert
en.CompMain=NV-AI (server, ComfyUI, web interface)
de.CompMain=NV-AI (Server, ComfyUI, Weboberfläche)
en.CompAddon=NV-AI for PhotoCraft (add-on, needs PhotoCraft)
de.CompAddon=NV-AI für PhotoCraft (Add-on, braucht PhotoCraft)
en.IconStop=Quit NV-AI
de.IconStop=NV-AI beenden
en.IconRepair=Repair NV-AI
de.IconRepair=NV-AI reparieren
en.IconFirstSteps=Getting Started
de.IconFirstSteps=Erste Schritte
en.FirstStepsFile=GETTING_STARTED.txt
de.FirstStepsFile=ERSTE_SCHRITTE.txt
en.IconAddon=NV-AI for PhotoCraft
de.IconAddon=NV-AI für PhotoCraft
en.RunNow=Start NV-AI now
de.RunNow=NV-AI jetzt starten
en.DirCaption=Data and models
de.DirCaption=Daten und Modelle
en.DirDescription=Where should images and models be stored?
de.DirDescription=Wo sollen Bilder und Modelle liegen?
en.DirSub=Each model is 5 to 30 GB. A folder on a large drive is a good choice.
de.DirSub=Jedes Modell ist 5 bis 30 GB groß. Ein Ordner auf einer großen Platte ist sinnvoll.
en.DirData=Data (images, settings, logs):
de.DirData=Daten (Bilder, Einstellungen, Protokolle):
en.DirModels=Models:
de.DirModels=Modelle:
en.DirInside=Data and model folders must not be inside the program folder (%1).%n%nUninstalling removes the program folder; models and images should survive that. Please choose a folder outside.
de.DirInside=Daten- und Modellordner dürfen nicht im Programmordner liegen (%1).%n%nDie Deinstallation entfernt den Programmordner; Modelle und Bilder sollen dabei erhalten bleiben. Bitte einen Ordner außerhalb wählen.
en.NoGpu=No NVIDIA graphics card with a driver was found.%n%nNV-AI computes on an NVIDIA card. Without one it installs, but cannot generate anything.%n%nInstall anyway?
de.NoGpu=Es wurde keine NVIDIA-Grafikkarte mit Treiber gefunden.%n%nNV-AI rechnet auf einer NVIDIA-Karte. Ohne sie lässt es sich installieren, erzeugt aber nichts.%n%nTrotzdem installieren?
en.OldDriver=Found: %1%n%nThe graphics driver %2 is too old. NV-AI needs at least version %3.%nPlease update first via https://www.nvidia.com/drivers%n%nInstall anyway?
de.OldDriver=Gefunden: %1%n%nDer Grafiktreiber %2 ist zu alt. NV-AI braucht mindestens Version %3.%nBitte zuerst über https://www.nvidia.com/drivers aktualisieren.%n%nTrotzdem installieren?
en.NoPhotoCraft=The add-on needs PhotoCraft (0.10.0 or newer), which is not installed here yet.%n%nOpen the download page now?
de.NoPhotoCraft=Das Add-on braucht PhotoCraft (ab 0.10.0), das hier noch nicht installiert ist.%n%nDownload-Seite jetzt öffnen?
en.RuntimeStatus=Setting up Python, ComfyUI and PyTorch (about 3 GB) ...
de.RuntimeStatus=Python, ComfyUI und PyTorch werden eingerichtet (rund 3 GB) ...
en.RuntimeFailed=The setup did not complete.%n%nLog: %1%nTry again later: Start menu → "Repair NV-AI".
de.RuntimeFailed=Die Einrichtung ist nicht vollständig durchgelaufen.%n%nProtokoll: %1%nSpäter erneut versuchen: Startmenü → „NV-AI reparieren“.
en.DeleteData=Delete the data as well?%n%n%1%n%2%n%nThey contain the generated images and the downloaded models. With "No" they are kept for a later installation.
de.DeleteData=Auch die Daten löschen?%n%n%1%n%2%n%nDarin liegen die erzeugten Bilder und die geladenen Modelle. Bei „Nein“ bleiben sie für eine spätere Installation erhalten.

[Types]
Name: "full"; Description: "{cm:TypeFull}"
Name: "basis"; Description: "{cm:TypeBasic}"
Name: "custom"; Description: "{cm:TypeCustom}"; Flags: iscustom

[Components]
Name: "main"; Description: "{cm:CompMain}"; Types: full basis custom; Flags: fixed
Name: "mesh3d"; Description: "{cm:Comp3D}"; Types: full
#if WithAddon == "1"
Name: "addon"; Description: "{cm:CompAddon}"; Types: full
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#StageDir}\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: main
Source: "{#StageDir}\triposg\*"; DestDir: "{app}\external\triposg"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: mesh3d
#if WithAddon == "1"
Source: "{#StageDir}\addon\*"; DestDir: "{app}\addon"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: addon
#endif

[Registry]
; Connection point for the PhotoCraft bridge and the launcher (nvai\launcher.py).
Root: HKCU; Subkey: "Software\NV-AI"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\NV-AI"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"
Root: HKCU; Subkey: "Software\NV-AI"; ValueType: string; ValueName: "Version"; ValueData: "{#AppVersion}"
Root: HKCU; Subkey: "Software\NV-AI"; ValueType: string; ValueName: "DataDir"; ValueData: "{code:GetDataDir}"
Root: HKCU; Subkey: "Software\NV-AI"; ValueType: string; ValueName: "ModelDir"; ValueData: "{code:GetModelDir}"
Root: HKCU; Subkey: "Software\NV-AI"; ValueType: dword; ValueName: "Port"; ValueData: "8100"; Flags: createvalueifdoesntexist

[Icons]
Name: "{group}\NV-AI"; Filename: "{app}\server\.venv\Scripts\pythonw.exe"; Parameters: "-m nvai.launcher --open"; WorkingDir: "{app}\server"; IconFilename: "{app}\nvai.ico"
Name: "{group}\{cm:IconStop}"; Filename: "{app}\server\.venv\Scripts\pythonw.exe"; Parameters: "-m nvai.launcher --stop"; WorkingDir: "{app}\server"; IconFilename: "{app}\nvai.ico"
Name: "{group}\{cm:IconRepair}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install-runtime.ps1"" -App ""{app}"" -DataDir ""{code:GetDataDir}"" {code:RuntimeSwitches}"; WorkingDir: "{app}"
Name: "{group}\{cm:IconFirstSteps}"; Filename: "{app}\{cm:FirstStepsFile}"
#if WithAddon == "1"
Name: "{group}\{cm:IconAddon}"; Filename: "{app}\addon\.venv\Scripts\pythonw.exe"; Parameters: "-m bridge --launch"; WorkingDir: "{app}\addon"; IconFilename: "{app}\addon\panel\icon.ico"; AppUserModelID: "NVAI.PhotoCraft"; Components: addon
#endif
Name: "{autodesktop}\NV-AI"; Filename: "{app}\server\.venv\Scripts\pythonw.exe"; Parameters: "-m nvai.launcher --open"; WorkingDir: "{app}\server"; IconFilename: "{app}\nvai.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\server\.venv\Scripts\pythonw.exe"; Parameters: "-m nvai.launcher --open"; WorkingDir: "{app}\server"; Description: "{cm:RunNow}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-all.ps1"" -App ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "StopAll"

[UninstallDelete]
; Only our own subfolders, never {app} as a whole: with the model folder inside the program
; folder (C:\NV-AI\models, chosen like that on 2026-10-19) uninstalling would have deleted
; the models without asking. The setup page no longer allows that (NextButtonClick).
Type: filesandordirs; Name: "{app}\python"
Type: filesandordirs; Name: "{app}\.uv-cache"
Type: filesandordirs; Name: "{app}\server"
Type: filesandordirs; Name: "{app}\external"
Type: filesandordirs; Name: "{app}\addon"
Type: filesandordirs; Name: "{app}\frontend"
Type: filesandordirs; Name: "{app}\locks"
Type: filesandordirs; Name: "{app}\tools"
Type: filesandordirs; Name: "{app}\licenses"
Type: dirifempty; Name: "{app}"

[Code]
var
  DirPage: TInputDirWizardPage;
  GpuLine: String;
  UninstDataDir, UninstModelDir: String;
  RuntimeFailed: Boolean;

{ Silent installs (tests, distribution) should see a failure in the exit code. }
function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if RuntimeFailed then
    Result := 1;
end;

function PrevValue(const Name, Default: String): String;
begin
  if not RegQueryStringValue(HKCU, 'Software\NV-AI', Name, Result) then
    Result := Default;
end;

function GetDataDir(Param: String): String;
begin
  Result := DirPage.Values[0];
end;

function GetModelDir(Param: String): String;
begin
  Result := DirPage.Values[1];
end;

{ Switches for install-runtime.ps1: which optional environments to set up. }
function RuntimeSwitches(Param: String): String;
begin
  Result := '';
  if WizardIsComponentSelected('mesh3d') then
    Result := Result + ' -With3D';
#if WithAddon == "1"
  if WizardIsComponentSelected('addon') then
    Result := Result + ' -WithAddon';
#endif
end;

procedure CaptureFirstLine(const S: String; const Error, FirstLine: Boolean);
begin
  if not Error and (GpuLine = '') and (Trim(S) <> '') then
    GpuLine := Trim(S);
end;

function LastCommaPos(const S: String): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := Length(S) downto 1 do
    if S[I] = ',' then
    begin
      Result := I;
      exit;
    end;
end;

{ "NVIDIA GeForce RTX 5060 Ti, 591.44" -> True if the driver is new enough. }
function DriverOk(const Line: String; var Version: String): Boolean;
var
  P, Major, Minor: Integer;
begin
  Version := Trim(Copy(Line, LastCommaPos(Line) + 1, 20));
  P := Pos('.', Version);
  Major := StrToIntDef(Copy(Version, 1, P - 1), 0);
  Minor := StrToIntDef(Copy(Version, P + 1, 2), 0);
  Result := (Major > {#MinDriverMajor}) or ((Major = {#MinDriverMajor}) and (Minor >= {#MinDriverMinor}));
end;

function InitializeSetup: Boolean;
var
  ResultCode: Integer;
  Version: String;
begin
  Result := True;
  GpuLine := '';
  try
    ExecAndLogOutput(ExpandConstant('{sys}\nvidia-smi.exe'),
      '--query-gpu=name,driver_version --format=csv,noheader', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode, @CaptureFirstLine);
  except
    GpuLine := '';
  end;
  if GpuLine = '' then
    Result := SuppressibleMsgBox(CustomMessage('NoGpu'), mbConfirmation, MB_YESNO, IDYES) = IDYES
  else if not DriverOk(GpuLine, Version) then
    { A line must not start with "[" - ISCC would read it as a section tag. }
    Result := SuppressibleMsgBox(FmtMessage(CustomMessage('OldDriver'), [GpuLine, Version,
      '{#MinDriverMajor}.' + Format('%.2d', [{#MinDriverMinor}])]),
      mbConfirmation, MB_YESNO, IDYES) = IDYES
  else
    Log('GPU: ' + GpuLine);
end;

function IsInside(const Dir, Parent: String): Boolean;
var
  D, P: String;
begin
  D := AddBackslash(Lowercase(ExpandFileName(Dir)));
  P := AddBackslash(Lowercase(ExpandFileName(Parent)));
  Result := Copy(D, 1, Length(P)) = P;
end;

{ Never put data and models into the program folder: uninstalling removes it. }
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = DirPage.ID then
    if IsInside(DirPage.Values[0], WizardDirValue) or IsInside(DirPage.Values[1], WizardDirValue) then
    begin
      SuppressibleMsgBox(FmtMessage(CustomMessage('DirInside'), [WizardDirValue]), mbError, MB_OK, IDOK);
      Result := False;
    end;
end;

procedure InitializeWizard;
begin
  DirPage := CreateInputDirPage(wpSelectDir, CustomMessage('DirCaption'),
    CustomMessage('DirDescription'), CustomMessage('DirSub'), False, '');
  DirPage.Add(CustomMessage('DirData'));
  DirPage.Add(CustomMessage('DirModels'));
  DirPage.Values[0] := PrevValue('DataDir', ExpandConstant('{localappdata}\NV-AI'));
  DirPage.Values[1] := PrevValue('ModelDir', ExpandConstant('{localappdata}\NV-AI\models'));
end;

function WebView2Installed: Boolean;
var
  Version: String;
begin
  Result :=
    (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0')) or
    (RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0'));
end;

function PhotoCraftInstalled: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\photocraft.exe') or
            RegKeyExists(HKCU, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\photocraft.exe');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  OldApp: String;
begin
  Result := '';
  { On an update, first stop everything that runs from the old folder. }
  if RegQueryStringValue(HKCU, 'Software\NV-AI', 'InstallDir', OldApp) and
     FileExists(OldApp + '\stop-all.ps1') then
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + OldApp + '\stop-all.ps1" -App "' + OldApp + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure InstallWebView2;
var
  ResultCode: Integer;
begin
  try
    DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703',
      'MicrosoftEdgeWebview2Setup.exe', '', nil);
    Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Log('WebView2 installer: exit ' + IntToStr(ResultCode));
  except
    Log('WebView2 not installed: ' + GetExceptionMessage);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  ErrorCode: Integer;
begin
  if CurStep <> ssPostInstall then
    exit;
  ForceDirectories(GetDataDir(''));
  ForceDirectories(GetModelDir(''));
#if WithAddon == "1"
  if WizardIsComponentSelected('addon') then
  begin
    if not WebView2Installed then
      InstallWebView2;
    if not PhotoCraftInstalled then
      if SuppressibleMsgBox(CustomMessage('NoPhotoCraft'), mbInformation, MB_YESNO, IDNO) = IDYES then
        ShellExec('open', '{#PhotoCraftUrl}', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
  end;
#endif
  WizardForm.StatusLabel.Caption := CustomMessage('RuntimeStatus');
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
       '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\install-runtime.ps1" -App "' +
       ExpandConstant('{app}') + '" -DataDir "' + GetDataDir('') + '" ' + RuntimeSwitches(''),
       ExpandConstant('{app}'), SW_SHOW, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
  begin
    RuntimeFailed := True;
    SuppressibleMsgBox(FmtMessage(CustomMessage('RuntimeFailed'), [GetDataDir('') + '\install.log']),
      mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir, ModelDir: String;
begin
  { The registry key is already gone after usUninstall - remember the folders first. }
  if CurUninstallStep = usUninstall then
  begin
    UninstDataDir := PrevValue('DataDir', '');
    UninstModelDir := PrevValue('ModelDir', '');
    exit;
  end;
  if CurUninstallStep <> usPostUninstall then
    exit;
  DataDir := UninstDataDir;
  ModelDir := UninstModelDir;
  if (DataDir <> '') and DirExists(DataDir) then
    if SuppressibleMsgBox(FmtMessage(CustomMessage('DeleteData'), [DataDir, ModelDir]),
       mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
    begin
      if (ModelDir <> '') and DirExists(ModelDir) then
        DelTree(ModelDir, True, True, True);
      DelTree(DataDir, True, True, True);
    end;
end;
