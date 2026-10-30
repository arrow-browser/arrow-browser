# Installs what Arrow.dll needs next to it to run: Arrow.exe (CEF's bootstrap
# executable, which loads Arrow.dll and sandboxes Chromium's subprocesses),
# the CEF runtime, the Swift runtime, and the Windows App SDK's bootstrapper
# and WinUI's resources.
#
#   powershell -File Windows\stage.ps1 [-Console] <directory of Arrow.dll>
#
# -Console installs bootstrapc.exe instead, which keeps a console (CI,
# debugging).
param(
    [Parameter(Mandatory)] [string] $Destination,
    [switch] $Console
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cef = if ($env:CEF_ROOT) { $env:CEF_ROOT } else { Join-Path $root '..\Vendor\cef' }
if (-not (Test-Path (Join-Path $cef 'Release'))) { throw "no CEF distribution in $cef. Run scripts/fetch-cef.sh" }
if (-not (Test-Path (Join-Path $Destination 'Arrow.dll'))) { throw "no Arrow.dll in $Destination. Run swift build --product Arrow" }
$packages = Join-Path $root '.packages'
if (-not (Test-Path $packages)) { throw "no Windows App SDK in $packages. Run generate-winrt.ps1" }

# The CEF runtime, and CEF's bootstrap as Arrow.exe.
foreach ($directory in 'Release', 'Resources') {
    Get-ChildItem (Join-Path $cef $directory) | Where-Object { $_.Name -notlike '*.lib' -and $_.Name -notlike 'bootstrap*.exe' } |
        Copy-Item -Destination $Destination -Recurse -Force
}
$bootstrap = if ($Console) { 'bootstrapc.exe' } else { 'bootstrap.exe' }
Copy-Item (Join-Path $cef "Release\$bootstrap") (Join-Path $Destination 'Arrow.exe') -Force

# Sandboxed processes do not look for DLLs in PATH: the Swift runtime goes
# next to Arrow.exe, as an installer would put it.
$swiftCore = where.exe swiftCore.dll | Select-Object -First 1
if (-not $swiftCore) { throw 'swiftCore.dll is not in PATH' }
Copy-Item (Join-Path (Split-Path $swiftCore) '*.dll') $Destination -Force

# The Windows App SDK's bootstrapper, and the resources of WinUI's controls.
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    'AMD64' { 'x64' }
    default { throw "unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$bootstrapper = Get-ChildItem "$packages\Microsoft.WindowsAppSDK.Foundation.*\runtimes\win-$architecture\native\Microsoft.WindowsAppRuntime.Bootstrap.dll"
Copy-Item $bootstrapper.FullName $Destination -Force
$resources = Get-ChildItem "$packages\Microsoft.WindowsAppSDK.WinUI.*\runtimes-framework\win-$architecture\native\Microsoft.UI.Xaml.Controls.pri"
Copy-Item $resources.FullName (Join-Path $Destination 'resources.pri') -Force
Write-Host "Arrow staged in $Destination"
