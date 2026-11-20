# The update manifest for a Windows release (app/src/updates.rs, docs/specs/SPEC-windows.md §7).
#
# Signs the finished installer — after SignPath, so the signature is of the file people download — with AI Hub Bar's
# own update key (TAURI_SIGNING_PRIVATE_KEY, a repository secret; the public part is in app/tauri.conf.json) and
# writes latest.json next to it: the version, the installer's address in the release `desktop-v<version>` and the
# signature. The release workflow attaches latest.json to the draft release; once the release is published,
# .github/workflows/desktop-update-manifest.yml copies it to the release `desktop-updates`, where installed copies
# look for it.
#
#     pwsh scripts/update-manifest.ps1 -Version 0.1.2
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Repository = 'OlehDemishev/AIHubBar',
    [string]$Folder = 'target/release/bundle/nsis'
)
$ErrorActionPreference = 'Stop'

if (-not $env:TAURI_SIGNING_PRIVATE_KEY) { Write-Error 'TAURI_SIGNING_PRIVATE_KEY is not set: no update manifest without the update key'; exit 1 }
$installer = Get-ChildItem (Join-Path $Folder '*-setup.exe') | Select-Object -First 1
if (-not $installer) { Write-Error "no installer in $Folder"; exit 1 }

# No prompt for a password: the key has none.
$env:CI = 'true'
if ($null -eq $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD) { $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = '' }
npx tauri signer sign $installer.FullName | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error 'the installer was not signed for the updater'; exit 1 }
$signature = (Get-Content "$($installer.FullName).sig" -Raw).Trim()
if (-not $signature) { Write-Error 'the signature is empty'; exit 1 }

# GitHub puts a dot where a release file's name has a space.
$asset = $installer.Name -replace ' ', '.'
$manifest = [ordered]@{
    version   = $Version
    pub_date  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    notes     = "https://github.com/$Repository/releases/tag/desktop-v$Version"
    platforms = [ordered]@{
        'windows-x86_64' = [ordered]@{
            signature = $signature
            url       = "https://github.com/$Repository/releases/download/desktop-v$Version/$asset"
        }
    }
}
$path = Join-Path $installer.DirectoryName 'latest.json'
[IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "update manifest for ${Version}: $path ($asset)"
