# Cloud-Codex

Cloud-Codex is an isolated Codex Desktop launcher profile for cloud model routing.

This redistributable baseline does not include Codex, Hermes, credentials, logs,
generated model catalogs, or Electron profile state. It installs only local
launcher/bridge scripts that discover the user's existing Codex and Hermes
installations at runtime.

## What This Baseline Does

- Keeps the default Codex profile untouched.
- Creates an isolated Codex home under `%USERPROFILE%\.codex-nous-cloud`.
- Adds a desktop launcher named `Cloud-Codex.lnk`.
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
- Provides companion controls for Hermes Golden updates and Hermes session
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

Because Cloud-Codex launches the signed Codex Desktop executable, Windows still
shows the app identity as `Codex` in Alt-Tab. Showing `Asclepius` there requires
a separately packaged app wrapper; this package does not modify or repackage
Codex Desktop.

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

## Install

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexNousCloud.ps1
```

Then open `Cloud-Codex.lnk` from the desktop.

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
