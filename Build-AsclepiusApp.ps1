$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $Root "AsclepiusApp.cs"
$Output = Join-Path $Root "Asclepius.exe"

if (-not (Test-Path -LiteralPath $Source)) {
  throw "Missing source file: $Source"
}

$candidates = @(
  (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
  (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
  throw "Could not find the .NET Framework C# compiler."
}

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
  /out:$Output `
  /reference:System.dll `
  /reference:System.Core.dll `
  /reference:System.Drawing.dll `
  /reference:System.Windows.Forms.dll `
  /reference:System.Web.Extensions.dll `
  $Source

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output)) {
  throw "Asclepius build failed."
}

Write-Output "Built $Output"
