# Installs the NSIS installer silently, checks what it promises, uninstalls and checks it cleaned up
# (docs/specs/SPEC-windows.md §7, CODE_SIGNING.md «What the Windows installer changes»). Run by CI on windows-latest after `npx tauri build --bundles nsis`; it touches only
# the runner's own user (HKCU, %LOCALAPPDATA%, the Start menu).
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

function Fail($message) { Write-Error "installer check: $message"; exit 1 }
function UserPath { (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames') }

$installer = Get-ChildItem 'target/release/bundle/nsis/*.exe' | Select-Object -First 1
if (-not $installer) { Fail 'no installer built' }
Write-Host "installing $($installer.Name)"
# A Path entry that must survive both the install and the uninstall unexpanded.
New-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value ((@((UserPath) -split ';' | Where-Object { $_ }) + '%USERPROFILE%\aihubbar-check') -join ';') -PropertyType ExpandString -Force | Out-Null
Start-Process $installer.FullName -ArgumentList '/S' -Wait

$app = Get-ChildItem $env:LOCALAPPDATA -Filter 'AIHubBar.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { Fail 'AIHubBar.exe not installed under %LOCALAPPDATA%' }
$dir = $app.DirectoryName
Write-Host "installed in $dir"
foreach ($name in 'claudepult.exe', 'claudepult-hook.exe') {
    if (-not (Test-Path (Join-Path $dir $name))) { Fail "$name not next to the app" }
}
$shortcut = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Filter 'AI Hub Bar*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $shortcut) { Fail 'no Start menu shortcut (notifications need it)' }
$parts = (UserPath) -split ';'
if ($parts -notcontains $dir) { Fail "the install folder is not in the user's Path: $(UserPath)" }
if ($parts -notcontains '%USERPROFILE%\aihubbar-check') { Fail 'the install expanded or lost an existing Path entry' }
if (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\Classes\.claudepult')) { Fail '.claudepult is not registered' }
$version = & (Join-Path $dir 'claudepult.exe') --version | Out-String
if ($version -notmatch '^\s*\d+\.\d+') { Fail "claudepult.exe --version said: $version" }
Write-Host 'installed: app, claudepult.exe, Start menu shortcut, Path, .claudepult'

$uninstaller = Join-Path $dir 'uninstall.exe'
if (-not (Test-Path $uninstaller)) { Fail 'no uninstall.exe' }
# `_?=` keeps the uninstaller in place, so -Wait waits for the real work.
Start-Process $uninstaller -ArgumentList '/S', "_?=$dir" -Wait
$parts = (UserPath) -split ';'
if ($parts -contains $dir) { Fail "the uninstaller left the folder in the user's Path: $(UserPath)" }
if ($parts -notcontains '%USERPROFILE%\aihubbar-check') { Fail 'the uninstall expanded or lost an existing Path entry' }
if (Test-Path (Join-Path $dir 'AIHubBar.exe')) { Fail 'AIHubBar.exe is still there' }
if (Test-Path 'Registry::HKEY_CURRENT_USER\Software\Classes\.claudepult') { Fail '.claudepult is still registered' }
Write-Host 'uninstalled: app gone, Path back as it was'
