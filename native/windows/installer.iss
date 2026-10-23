#ifndef AppSource
  #error AppSource must point to the published application directory
#endif
#ifndef OutputDirectory
  #define OutputDirectory "artifacts"
#endif
[Setup]
AppId={{1F65F702-1F17-4F98-B245-1AC17F3B5DB9}
AppName=S1Print
AppVersion=0.4.0
AppPublisher=Marvin Quevedo
DefaultDirName={localappdata}\Programs\S1Print
DefaultGroupName=S1Print
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDirectory}
OutputBaseFilename=S1Print-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\S1Print.exe
CloseApplications=yes
[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\S1Print"; Filename: "{app}\S1Print.exe"
[Run]
Filename: "{app}\S1Print.exe"; Description: "Open S1Print"; Flags: nowait postinstall skipifsilent
[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -NonInteractive -Command ""Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name S1Print -ErrorAction SilentlyContinue"""; Flags: runhidden
