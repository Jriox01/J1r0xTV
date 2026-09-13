[Setup]
AppId={{A75C2C34-6C9E-4D57-BDAA-19B97830E452}
AppName=J1r0x TV
AppVersion=1.0
AppPublisher=Zhernossek
DefaultDirName={autopf}\J1r0x TV
DefaultGroupName=J1r0x TV
OutputDir=installer
OutputBaseFilename=J1r0xTV_Setup_v1.0
SetupIconFile=assets\icon.ico
UninstallDisplayIcon={app}\J1r0x TV.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

[Files]
Source: "dist\J1r0x TV\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\J1r0x TV"; Filename: "{app}\J1r0x TV.exe"; IconFilename: "{app}\J1r0x TV.exe"
Name: "{autodesktop}\J1r0x TV"; Filename: "{app}\J1r0x TV.exe"; IconFilename: "{app}\J1r0x TV.exe"

[Run]
Filename: "{app}\J1r0x TV.exe"; Description: "Запустить J1r0x TV"; Flags: nowait postinstall skipifsilent
