# Cloud-Codex

Cloud-Codex is an isolated Codex Desktop launcher profile for cloud model routing.
Asclepius is the Windows supervisor app that owns the user-facing control
surface while keeping Codex Desktop and Hermes independently updateable.
Its normal ready state and first-run wizard both use the same Codex-like app
shell: sidebar navigation, a central conversation surface, and a bottom
composer with model/provider controls.

This redistributable baseline does not include Codex, Hermes, credentials, logs,
generated model catalogs, or Electron profile state. It installs only local
launcher/bridge scripts that discover the user's existing Codex and Hermes
installations at runtime.

## What This Baseline Does

- Keeps the default Codex profile untouched.
- Creates an isolated Codex home under `%USERPROFILE%\.codex-nous-cloud`.
- Builds a local `Asclepius.exe` supervisor app and adds a desktop launcher
  named `asclepius.lnk`.
- Presents first-run setup and normal launch inside one shared Codex-style UI
  instead of switching between wizard and utility-window layouts.
- Starts a local-only Responses bridge on `127.0.0.1:8655`.
- Starts Hermes' Nous OAuth proxy on `127.0.0.1:8645` when needed.
- Routes Codex turns through `hermes chat` by default so Hermes sessions,
  memory, skills, and learning are in the turn path.
- Injects an Asclepius runtime capsule into Hermes so it knows the selected
  Codex profile policy, active model route, and Windows/WSL workspace mapping.
- Refreshes a live provider/model/price catalog from Nous and OpenRouter.
- Shows provider-qualified model routes, for example:
  - `Nous Portal via Hermes OAuth | deepseek/deepseek-v4-flash`
  - `OpenRouter | deepseek/deepseek-v4-flash`
- Supports Hermes OAuth login for free Nous models.
- Supports optional direct provider API keys stored only in the installed local profile.
- Provides in-app controls for Hermes Golden updates and Hermes session
  deletion without modifying Codex Desktop's own updater.

## Architecture

The first packaged checkpoint used Hermes as an OAuth/model proxy. This source
now routes Codex turns through Hermes Agent:

```text
Codex Desktop -> local Responses bridge -> hermes chat -> Hermes Agent runtime -> cloud providers
```

The bridge stores the Hermes session id for each Codex response id and resumes
the Hermes session when Codex sends `previous_response_id`.

Hermes executes tools in its own WSL runtime. The Codex Desktop sandbox selector
is visible profile intent, not a hard sandbox around Hermes tools, so the bridge
adds that policy and workspace mapping to each Hermes turn.

Asclepius owns its supervisor window and launcher identity. When it launches
the signed Codex Desktop executable, Codex's own editing/chat window still
belongs to Codex. This package does not modify or repackage Codex Desktop.

## Design Discipline

- **12FA:** Codex and Hermes are explicit external dependencies; runtime config
  is passed through environment variables and isolated profile files; build,
  install, and run are separate scripts; child processes are disposable; logs
  stream into the Asclepius UI/status surface.
- **Nemawashi:** Asclepius is a supervisor beside Codex, not a Codex patch.
  Affected owners are Codex Desktop, Hermes Agent, and the local Asclepius
  profile. Rollback is replacing `asclepius.lnk` with the old VBS picker target
  or launching `Launch-CloudCodexModelPicker.vbs` directly.
- **ZTA:** Sensitive actions route through local scripts under the Asclepius
  root, confirm paid/unknown models, and keep Hermes updates/session deletion
  behind explicit user action.
- **Secret Egress Filter:** The supervisor redacts common token/key/cookie
  shapes before showing command output in the UI.
- **SOLID:** Asclepius keeps separate responsibilities for app supervision,
  model catalog loading, process launch, secret filtering, and smoke checks.
  Provider/model sections are data-driven so adding a route should not require
  renderer rewrites.
- **Normal Form:** Workspace paths are canonicalized and converted to WSL paths
  before being handed to Hermes.
- **E2E:** `Test-Asclepius.ps1` keeps the critical path small but meaningful:
  syntax/build, installed app smoke, visible window identity, shortcut target,
  default Codex profile observation, and package hygiene.
- **WCAG / POUR:** The app uses high-contrast text, visible status text,
  keyboard-operable buttons, accessible names on major controls, and smoke
  assertions for contrast and basic operability metadata.
- **PE:** First-run content works before services or catalogs are ready: the
  shared Codex-style shell shows dependency status, install actions, and a safe
  fallback Nous route, then progressively enables richer launch/model behavior
  as checks pass.

Set `CODEX_CLOUD_RUNTIME_MODE=proxy` before starting the bridge to force the
older raw model-proxy behavior for debugging.

Long Hermes turns, including context compression, may not yield token deltas
until Hermes finishes. The streaming bridge sends SSE keepalive comments during
those waits so Codex does not look silently disconnected.

## Updates And Memory

Codex Desktop's blue `Update` control remains Codex-only. Use the Asclepius
picker's `Hermes Golden Update` button, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-HermesGolden.ps1
```

To inspect or delete Hermes sessions from the Hermes store, use the picker's
`Hermes Sessions` button, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-AsclepiusHermesSessions.ps1
```

## Requirements

- Windows with PowerShell.
- Codex Desktop installed separately.
- WSL Ubuntu with Hermes installed at `/home/agent/.local/bin/hermes`.
- A Hermes Nous OAuth login for free Nous Portal models.

If Codex, WSL Ubuntu, Hermes, or Python are missing, Asclepius shows first-run
install buttons with progress logs instead of launching into a broken profile.

## Install

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexNousCloud.ps1
```

Then open `asclepius.lnk` from the desktop.

If the picker says Nous OAuth login is needed, click `Nous OAuth Login`.

## Provider Auth

Nous free models use Hermes OAuth by default. No Nous API key is required for
free Nous routes.

Optional keys may be set in the picker:

- `Set Nous API Key`: optional direct Nous API auth.
- `Set OpenRouter Key`: required for OpenRouter routes.

Installed keys are written only to:

```text
%USERPROFILE%\.codex-nous-cloud\cloud-secrets.json
```

That file is intentionally ignored by git and excluded from packages.

## Package

After committing the repo, create a redistributable zip:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Package-CloudCodex.ps1
```

The package contains git-tracked source files only.

## Smoke

To run the local verification harness:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Asclepius.ps1
```

Use `-SkipInstalled` for source/package-only checks before installation.
