# Generates the Swift projections of the WinRT APIs the Windows app uses
# (projections.json) with swift-winrt: Sources/CWinRT and
# Sources/<module>/Generated, which are not versioned. Adapted from The
# Browser Company's swift-winui (BSD-3-Clause).
#
#   powershell -File Windows\generate-winrt.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configFile = Join-Path $root 'projections.json'
$config = Get-Content -Raw $configFile | ConvertFrom-Json

# NuGet packages: swift-winrt, and the Windows App SDK with its metadata
# (.winmd). Fetched again when projections.json changes.
$packages = Join-Path $root '.packages'
$stamp = Join-Path $packages 'projections.json'
if ((Test-Path $stamp) -and ((Get-Content -Raw $stamp) -ne (Get-Content -Raw $configFile))) {
    Remove-Item -Recurse -Force $packages
}
New-Item -ItemType Directory -Force $packages | Out-Null
$nuget = Join-Path $packages 'nuget.exe'
if (-not (Test-Path $nuget)) {
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nuget
}
foreach ($package in @(@('TheBrowserCompany.SwiftWinRT', $config.swiftWinRT), @('Microsoft.WindowsAppSDK', $config.windowsAppSDK))) {
    & $nuget install $package[0] -Version $package[1] -OutputDirectory $packages -NonInteractive -Verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "nuget install $($package[0]) $($package[1]) failed" }
}
Copy-Item $configFile $stamp

# The Windows API metadata comes from the Windows SDK, which Swift requires.
$unionMetadata = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\UnionMetadata'
$windowsMetadata = Get-ChildItem $unionMetadata -Directory | Where-Object Name -match '^\d+\.' |
    Sort-Object { [version]$_.Name } | Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName 'Windows.winmd' }
if (-not $windowsMetadata -or -not (Test-Path $windowsMetadata)) { throw "no Windows SDK metadata in $unionMetadata" }

# swift-winrt projects the included types and those their members use.
$output = Join-Path $packages 'generated'
if (Test-Path $output) { Remove-Item -Recurse -Force $output }
$rsp = @("-output $output", "-input `"$windowsMetadata`"")
$rsp += $config.include | ForEach-Object { "-include $_" }
foreach ($pattern in $config.inputs) {
    $files = @(Get-ChildItem -Path (Join-Path $packages $pattern) -File)
    if ($files.Count -eq 0) { throw "no metadata matches $pattern" }
    $rsp += $files | ForEach-Object { "-input `"$($_.FullName)`"" }
}
$rspFile = Join-Path $packages 'swift-winrt.rsp'
$rsp | Out-File -Encoding ascii $rspFile
& (Join-Path $packages "TheBrowserCompany.SwiftWinRT.$($config.swiftWinRT)\bin\swiftwinrt.exe") "@$rspFile"
if ($LASTEXITCODE -ne 0) { throw "swiftwinrt failed ($LASTEXITCODE)" }

# CWinRT is generated whole; the Swift modules keep their hand-written files.
foreach ($module in $config.modules) {
    $destination = if ($module -eq 'CWinRT') { Join-Path $root 'Sources\CWinRT' } else { Join-Path $root "Sources\$module\Generated" }
    if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    Copy-Item -Recurse (Join-Path $output "Sources\$module") $destination
}
Write-Host "WinRT projections generated in $(Join-Path $root 'Sources')"
