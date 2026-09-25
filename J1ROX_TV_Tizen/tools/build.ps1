param(
    [Parameter(Mandatory = $true)][string]$CertificateProfile,
    [string]$TizenCli = 'C:\tizen-studio\tools\ide\bin\tizen.bat'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $TizenCli -PathType Leaf)) {
    throw "Tizen CLI not found: $TizenCli. Install Tizen Studio with TV extensions; see SAMSUNG-TV-INSTALL.md. No WGT has been built."
}
# A fresh staging directory includes only runtime assets. Tests, keys and documentation never enter the package.
$stageRoot = Join-Path $projectRoot ('.build\stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
foreach ($entry in @('config.xml', 'index.html', 'js', 'css', 'assets')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $entry) -Destination $stageRoot -Recurse
}
& $TizenCli build-web -- $stageRoot
if ($LASTEXITCODE -ne 0) { throw 'Tizen build-web failed.' }
$buildRoot = Join-Path $stageRoot '.buildResult'
& $TizenCli package -t wgt -s $CertificateProfile -- $buildRoot
if ($LASTEXITCODE -ne 0) { throw 'Tizen signing/packaging failed. Check the Samsung certificate profile.' }
$packages = @(Get-ChildItem -LiteralPath $buildRoot -Filter '*.wgt' -File)
if ($packages.Count -ne 1 -or $packages[0].Length -le 0) { throw 'Expected one nonempty WGT from Tizen CLI.' }
$distRoot = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
$targetPackage = Join-Path $distRoot 'J1ROX-TV-Samsung.wgt'
Copy-Item -LiteralPath $packages[0].FullName -Destination $targetPackage -Force
Get-Item -LiteralPath $targetPackage | Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $targetPackage -Algorithm SHA256
