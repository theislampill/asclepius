$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Invoke-WslPythonJson {
  param([Parameter(Mandatory)][string]$Code)
  $output = $Code | wsl.exe -d Ubuntu -- python3 -
  if (-not $output) { return @() }
  return $output | ConvertFrom-Json
}

function Invoke-HermesDelete {
  param([Parameter(Mandatory)][string]$SessionId)
  & wsl.exe -d Ubuntu -- bash -lc "/home/agent/.local/bin/hermes sessions delete '$SessionId' --yes 2>&1"
}

function Load-Sessions {
  $code = @'
import json, sqlite3, pathlib, datetime
db=pathlib.Path("/home/agent/.hermes/state.db")
con=sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.row_factory=sqlite3.Row
rows=con.execute("""
select s.id, s.source, s.model, s.message_count, s.tool_call_count, s.started_at,
       coalesce(s.title, substr((select m.content from messages m where m.session_id=s.id and m.role='user' order by m.id limit 1),1,120)) as preview
from sessions s
order by s.started_at desc
limit 300
""").fetchall()
out=[]
for r in rows:
    d=dict(r)
    ts=d.get("started_at")
    try:
        d["started_local"]=datetime.datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")
    except Exception:
        d["started_local"]=""
    out.append(d)
print(json.dumps(out))
'@
  $rows = @(Invoke-WslPythonJson -Code $code)
  $map = Get-AsclepiusSessionMap
  foreach ($row in $rows) {
    $sid = [string]$row.id
    $responses = @($map[$sid])
    $row | Add-Member -NotePropertyName asclepius -NotePropertyValue ($(if ($responses.Count -gt 0) { "yes" } else { "" })) -Force
    $row | Add-Member -NotePropertyName codex_responses -NotePropertyValue ($responses -join ", ") -Force
  }
  return $rows
}

function Get-AsclepiusSessionMap {
  $path = Join-Path $PSScriptRoot "bridge-state.json"
  $map = @{}
  if (-not (Test-Path -LiteralPath $path)) { return $map }
  try {
    $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    foreach ($prop in @($state.responses.PSObject.Properties)) {
      $rid = [string]$prop.Name
      $sid = [string]$prop.Value.hermes_session_id
      if ([string]::IsNullOrWhiteSpace($sid)) {
        $sid = [string]$prop.Value.response.metadata.hermes_session_id
      }
      if ([string]::IsNullOrWhiteSpace($sid)) { continue }
      if (-not $map.ContainsKey($sid)) { $map[$sid] = New-Object System.Collections.Generic.List[string] }
      $map[$sid].Add($rid)
    }
  } catch {}
  return $map
}

function Remove-AsclepiusSessionMap {
  param([Parameter(Mandatory)][string]$SessionId)
  $path = Join-Path $PSScriptRoot "bridge-state.json"
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $keep = [ordered]@{}
    foreach ($prop in @($state.responses.PSObject.Properties)) {
      $sid = [string]$prop.Value.hermes_session_id
      if ([string]::IsNullOrWhiteSpace($sid)) {
        $sid = [string]$prop.Value.response.metadata.hermes_session_id
      }
      if ($sid -ne $SessionId) {
        $keep[$prop.Name] = $prop.Value
      }
    }
    $state.responses = [pscustomobject]$keep
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 80), $utf8NoBom)
  } catch {}
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Asclepius Hermes Sessions"
$form.Size = New-Object System.Drawing.Size(980, 560)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Text = "Hermes stores sessions in ~/.hermes/state.db and ~/.hermes/sessions. Delete removes a selected Hermes session from the Hermes store."
$label.Location = New-Object System.Drawing.Point(12, 12)
$label.Size = New-Object System.Drawing.Size(940, 34)
$form.Controls.Add($label)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(12, 52)
$grid.Size = New-Object System.Drawing.Size(940, 390)
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$form.Controls.Add($grid)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = "Refresh"
$refresh.Location = New-Object System.Drawing.Point(12, 456)
$refresh.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($refresh)

$delete = New-Object System.Windows.Forms.Button
$delete.Text = "Delete Selected"
$delete.Location = New-Object System.Drawing.Point(128, 456)
$delete.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($delete)

$browse = New-Object System.Windows.Forms.Button
$browse.Text = "Open Hermes Browse"
$browse.Location = New-Object System.Drawing.Point(274, 456)
$browse.Size = New-Object System.Drawing.Size(160, 34)
$form.Controls.Add($browse)

$status = New-Object System.Windows.Forms.Label
$status.Text = ""
$status.Location = New-Object System.Drawing.Point(450, 462)
$status.Size = New-Object System.Drawing.Size(500, 28)
$form.Controls.Add($status)

function Refresh-Grid {
  try {
    $status.Text = "Loading..."
    $form.Refresh()
    $rows = Load-Sessions
    $grid.DataSource = $rows
    $order = @("asclepius","id","source","model","message_count","tool_call_count","started_local","codex_responses","preview")
    foreach ($col in $order) {
      if ($grid.Columns[$col]) { $grid.Columns[$col].DisplayIndex = [Array]::IndexOf($order, $col) }
    }
    $status.Text = "Loaded $($rows.Count) Hermes sessions."
  } catch {
    $status.Text = "Load failed: $($_.Exception.Message)"
  }
}

$refresh.Add_Click({ Refresh-Grid })
$delete.Add_Click({
  if ($grid.SelectedRows.Count -lt 1) { return }
  $row = $grid.SelectedRows[0].DataBoundItem
  $sid = [string]$row.id
  if ([string]::IsNullOrWhiteSpace($sid)) { return }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "Delete Hermes session $sid?`r`n`r`nThis removes it from Hermes session history/memory search.",
    "Delete Hermes session",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $status.Text = "Deleting $sid..."
    $form.Refresh()
    $out = Invoke-HermesDelete -SessionId $sid
    Remove-AsclepiusSessionMap -SessionId $sid
    Refresh-Grid
    $status.Text = "Deleted $sid. $out"
  } catch {
    $status.Text = "Delete failed: $($_.Exception.Message)"
  }
})
$browse.Add_Click({
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-NoExit",
    "-Command",
    "wsl.exe -d Ubuntu -- /home/agent/.local/bin/hermes sessions browse --limit 300"
  ) | Out-Null
})

$form.Add_Shown({ Refresh-Grid })
[void]$form.ShowDialog()
