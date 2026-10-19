; ZeroApi (零汇) — Windows 安装包脚本 (Inno Setup 6)
; 用法（在项目根目录，已先 flutter build windows）：
;   iscc /DMyArch=arm64 /DMyVersion=0.1.2 packaging\zeroapi.iss
;   （iscc 位于 %LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe）
; 产物：installer\zeroapi-setup-<arch>-<version>.exe

#define MyAppName "ZeroApi"
#define MyAppNameCN "零汇"
#ifdef MyVersion
  #define MyAppVersion MyVersion
#else
  #define MyAppVersion "0.1.11"
#endif
#ifndef MyArch
  #define MyArch "arm64"
#endif
#define MyAppExeName "zeroapi.exe"

[Setup]
AppId={{7E0A9F1B-4C2D-4F3A-9B8E-0A1C2D3E4F50}
AppName={#MyAppName} ({#MyAppNameCN})
AppVersion={#MyAppVersion}
AppPublisher=Kepler16f
DefaultDirName={autopf}\ZeroApi
DefaultGroupName=ZeroApi
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=..\installer
OutputBaseFilename=zeroapi-setup-{#MyArch}-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#MyArch}
ArchitecturesInstallIn64BitMode={#MyArch}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=..\assets\icon\zeroapi.ico
; 卸载时保留用户配置 %APPDATA%\zeroapi（网关 key 与供应商配置），不做清理

[Languages]
Name: "chineseb"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\{#MyArch}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 旧版本随包分发的 zengate/opencode vendor（约 176MB）：直连实现后升级时彻底清理
Type: filesandordirs; Name: "{app}\vendor"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
