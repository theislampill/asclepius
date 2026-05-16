param(
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Invoke-UbuntuBash {
  param([Parameter(Mandatory)][string]$Script)
  & wsl.exe -d Ubuntu -- bash -lc $Script 2>$null
}

function Invoke-UbuntuBashLoose {
  param([Parameter(Mandatory)][string]$Script)
  try {
    return @(& wsl.exe -d Ubuntu -- bash -lc $Script 2>$null)
  } catch {
    return @()
  }
}

function First-Line {
  param($Value)
  $row = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)[0]
  if ($null -eq $row) { return "" }
  return ([string]$row).Trim()
}

$status = [ordered]@{
  installed = $false
  state = "missing"
  current_version = ""
  latest_version = ""
  behind = 0
  local_commit = ""
  remote_commit = ""
  version_line = ""
  summary = "Hermes not installed"
  tooltip = "Hermes was not found in WSL Ubuntu."
}

try {
  $wsl = Get-Command wsl.exe -ErrorAction Stop
  $installed = First-Line (Invoke-UbuntuBashLoose 'test -x /home/agent/.local/bin/hermes && test -d /home/agent/.hermes/hermes-agent/.git && echo yes')
  if ($installed -ne "yes") {
    throw "Hermes is not installed in the expected WSL path."
  }

  $status.installed = $true
  Invoke-UbuntuBashLoose 'cd /home/agent/.hermes/hermes-agent && git fetch --quiet origin' | Out-Null

  $status.version_line = First-Line (Invoke-UbuntuBashLoose '/home/agent/.local/bin/hermes version 2>/dev/null | head -1')
  $currentVersionLine = First-Line (Invoke-UbuntuBashLoose "cd /home/agent/.hermes/hermes-agent && grep -m1 -E '^version[[:space:]]*=' pyproject.toml")
  $latestVersionLine = First-Line (Invoke-UbuntuBashLoose "cd /home/agent/.hermes/hermes-agent && git show origin/main:pyproject.toml | grep -m1 -E '^version[[:space:]]*='")
  if ($currentVersionLine -match '"([^"]+)"') { $status.current_version = $matches[1] }
  if ($latestVersionLine -match '"([^"]+)"') { $status.latest_version = $matches[1] }
  $status.local_commit = First-Line (Invoke-UbuntuBashLoose 'cd /home/agent/.hermes/hermes-agent && git rev-parse --short HEAD')
  $status.remote_commit = First-Line (Invoke-UbuntuBashLoose 'cd /home/agent/.hermes/hermes-agent && git rev-parse --short origin/main')
  $behindText = First-Line (Invoke-UbuntuBashLoose 'cd /home/agent/.hermes/hermes-agent && git rev-list --count HEAD..origin/main')
  $behindValue = 0
  [void][int]::TryParse($behindText, [ref]$behindValue)
  $status.behind = $behindValue

  $current = if ($status.current_version) { "v$($status.current_version)" } elseif ($status.version_line -match 'v([0-9][^\s]+)') { "v$($matches[1])" } else { $status.local_commit }
  $latest = if ($status.latest_version) { "v$($status.latest_version)" } else { $status.remote_commit }
  if ($status.behind -gt 0) {
    $status.state = "outdated"
    $status.summary = "Hermes out of date: $($status.behind) commits behind"
    $status.tooltip = "Hermes is $($status.behind) commits behind. Current: $current ($($status.local_commit)). Latest: $latest ($($status.remote_commit))."
  } else {
    $status.state = "current"
    $status.summary = "Hermes up to date"
    $status.tooltip = "Hermes is up to date. Current: $current ($($status.local_commit))."
  }
} catch {
  $status.summary = "Hermes status unavailable"
  $status.tooltip = $_.Exception.Message
}

$result = [pscustomobject]$status
if ($Json) {
  $result | ConvertTo-Json -Compress
} else {
  $result
}
