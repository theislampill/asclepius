$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dist = Join-Path $Root "dist"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$PackageName = "cloud-codex-$Stamp.zip"
$PackagePath = Join-Path $Dist $PackageName
$Stage = Join-Path $env:TEMP "cloud-codex-package-$Stamp"

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
if (Test-Path -LiteralPath $Stage) {
  Remove-Item -LiteralPath $Stage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

try {
  $tracked = & git -C $Root ls-files
  if ($LASTEXITCODE -ne 0 -or -not $tracked) {
    throw "Package requires a git repo with tracked files. Run git init/add/commit first."
  }

  foreach ($rel in $tracked) {
    $src = Join-Path $Root $rel
    $dst = Join-Path $Stage $rel
    $dstDir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }

  & (Join-Path $Root "Build-AsclepiusLauncher.ps1") -OutputPath (Join-Path $Stage "Asclepius.exe") | Out-Null

  if (Test-Path -LiteralPath $PackagePath) {
    Remove-Item -LiteralPath $PackagePath -Force
  }
  Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $PackagePath -Force
  Write-Output "Wrote $PackagePath"
} finally {
  if (Test-Path -LiteralPath $Stage) {
    Remove-Item -LiteralPath $Stage -Recurse -Force
  }
}
