# Build release ZIP with addons/nexus_importer/ structure for manual installation and Godot Asset Library.
# Run from repo root: .\scripts\build_release.ps1
# Output: nexus_importer-<version>.zip

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Get-Location }
Push-Location $repoRoot | Out-Null

try {
    $pluginCfg = Join-Path $repoRoot "addons\nexus_importer\plugin.cfg"
    $version = (Select-String -Path $pluginCfg -Pattern 'version="([^"]+)"').Matches.Groups[1].Value
    if (-not $version) { throw "Could not read version from addons/nexus_importer/plugin.cfg" }

    $outZip = Join-Path $repoRoot "nexus_importer-$version.zip"
    $staging = Join-Path $repoRoot "build_staging"

    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Copy-Item -Path (Join-Path $repoRoot "addons") -Destination $staging -Recurse -Force
    if (Test-Path (Join-Path $repoRoot "LICENSE")) {
        Copy-Item -Path (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $staging "addons\nexus_importer\LICENSE") -Force
    }

    if (Test-Path $outZip) { Remove-Item $outZip -Force }
    Compress-Archive -Path (Join-Path $staging "addons") -DestinationPath $outZip -Force
    Remove-Item -Recurse -Force $staging

    Write-Host "Created $outZip (addons/nexus_importer/ structure). Extract to Godot project root."
}
finally {
    Pop-Location
}
