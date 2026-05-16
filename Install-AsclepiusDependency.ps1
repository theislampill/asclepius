param(
  [Parameter(Mandatory)]
  [ValidateSet("Codex", "WslUbuntu", "Hermes", "Python")]
  [string]$Target
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Output ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
}

function Require-Command {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) {
    throw "$Name was not found on PATH."
  }
  return $cmd.Source
}

function Install-CodexDesktop {
  Write-Step "Checking for winget..."
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    Write-Step "Installing Codex from Microsoft Store package 9PLM9XGG6VKS."
    & $winget.Source install --id 9PLM9XGG6VKS --source msstore --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) {
      Write-Step "Codex install completed."
      return
    }
    Write-Step "winget exited with code $LASTEXITCODE; opening Microsoft Store fallback."
  } else {
    Write-Step "winget not found; opening Microsoft Store fallback."
  }

  Start-Process "ms-windows-store://pdp/?productid=9PLM9XGG6VKS"
  Write-Step "Microsoft Store opened. Complete the Codex install there, then return to Asclepius and refresh."
}

function Install-WslUbuntu {
  Write-Step "Starting WSL Ubuntu install."
  Write-Step "Windows may ask for confirmation or require a reboot before Ubuntu can finish setup."
  $wsl = Require-Command "wsl.exe"
  & $wsl --install -d Ubuntu
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Step "wsl --install exited with code $code."
  }

  try {
    & $wsl --set-version Ubuntu 2
    Write-Step "Requested Ubuntu WSL2 version."
  } catch {
    Write-Step "Could not set Ubuntu to WSL2 yet: $($_.Exception.Message)"
  }
  Write-Step "WSL/Ubuntu step complete. If Windows requested a reboot, reboot before installing Hermes."
}

function Install-HermesWsl {
  $wsl = Require-Command "wsl.exe"
  Write-Step "Installing Hermes inside WSL Ubuntu using the upstream WSL/Linux installer."
  Write-Step "Source: https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
  $command = @'
set -e
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is missing; installing curl and ca-certificates with apt."
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git is missing; installing git with apt."
  sudo apt-get update
  sudo apt-get install -y git
fi
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
if [ -x "$HOME/.local/bin/hermes" ]; then
  "$HOME/.local/bin/hermes" --version
else
  echo "Hermes installer finished but ~/.local/bin/hermes was not found."
  exit 3
fi
'@
  & $wsl -d Ubuntu -- bash -lc $command
  if ($LASTEXITCODE -ne 0) {
    throw "Hermes WSL install exited with code $LASTEXITCODE."
  }
  Write-Step "Hermes WSL install completed."
}

function Install-Python {
  Write-Step "Checking for winget..."
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    Write-Step "Installing Python 3.12 with winget."
    & $winget.Source install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) {
      Write-Step "Python install completed."
      return
    }
    Write-Step "winget exited with code $LASTEXITCODE; opening Python downloads fallback."
  } else {
    Write-Step "winget not found; opening Python downloads fallback."
  }

  Start-Process "https://www.python.org/downloads/windows/"
  Write-Step "Python download page opened. Install Python, then return to Asclepius and refresh."
}

switch ($Target) {
  "Codex" { Install-CodexDesktop }
  "WslUbuntu" { Install-WslUbuntu }
  "Hermes" { Install-HermesWsl }
  "Python" { Install-Python }
}
