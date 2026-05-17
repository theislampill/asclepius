param(
  [string]$SourcePath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "AsclepiusLauncher.cs"),
  [string]$OutputPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Asclepius.exe")
)

$ErrorActionPreference = "Stop"

function Find-CSharpCompiler {
  $candidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $cmd = Get-Command csc.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "No C# compiler found. Install .NET Framework developer tools or use the packaged Asclepius.exe."
}

if (-not (Test-Path -LiteralPath $SourcePath)) {
  throw "Launcher source not found: $SourcePath"
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$compiler = Find-CSharpCompiler
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /out:$OutputPath /reference:System.Windows.Forms.dll $SourcePath
if ($LASTEXITCODE -ne 0) {
  throw "Asclepius launcher build failed."
}

Write-Output "Built $OutputPath"
