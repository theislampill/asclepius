# Cloud-Codex

Cloud-Codex is an isolated Codex Desktop launcher profile for cloud model routing.
Asclepius is a safe launcher/profile for the real signed Codex Desktop app. It
does not embed, parent, repackage, or modify the Codex window.

This redistributable baseline does not include Codex, Hermes, credentials, logs,
generated model catalogs, or Electron profile state. It installs only local
launcher/bridge scripts that discover the user's existing Codex and Hermes
installations at runtime.

## What This Baseline Does

- Keeps the default Codex profile untouched.
- Creates an isolated Codex home under `%USERPROFILE%\.codex-nous-cloud`.
- Adds a desktop launcher named `asclepius.lnk` that runs
  `Launch-AsclepiusProviderLauncher.vbs`, shows a standalone Asclepius
  provider/portal preflight screen, then opens the real Codex Desktop
  executable with Hermes underneath.
- Does not install an `Asclepius.exe` host. Earlier window-parenting host
  attempts were removed because they can destabilize Codex.
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
- Reuses the user's existing local Codex auth only at launch time by linking or
  copying `%USERPROFILE%\.codex\auth.json` into the local installed profile.
  Auth is never included in the redistributable package.
- Keeps Hermes Golden update and Hermes session deletion as separate helper
  scripts without modifying Codex Desktop's own updater.

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

Asclepius owns no chat window and does not draw a picker over Codex. Codex
starts only after a route is selected. The visible work app is Codex Desktop.
This package does not modify, embed, or repackage Codex Desktop.

When Codex launches through Asclepius, a hidden window-identity watcher targets
only the fresh Codex PID/HWND created by that launch. It keeps the window title
and AppUserModelID set to Asclepius, because Codex may reset its own title after
project or chat state changes.

## Design Discipline

- **12FA:** Codex and Hermes are explicit external dependencies; runtime config
  is passed through environment variables and isolated profile files; build,
  install, and run are separate scripts; child processes are disposable; logs
  stream through launcher/service logs.
- **Nemawashi:** Asclepius is a launcher/profile beside Codex, not a Codex
  patch, host, or fake Codex UI.
  Affected owners are Codex Desktop, Hermes Agent, and the local Asclepius
  profile. Rollback is launching `Launch-CloudCodexApp.vbs` directly or using
  normal Codex without the Asclepius shortcut.
- **ZTA:** Sensitive actions route through local scripts under the Asclepius
  root, confirm paid/unknown models, and keep Hermes updates/session deletion
  behind explicit user action.
- **Secret Egress Filter:** Local scripts avoid packaging or printing stored
  secrets; credentials remain in ignored profile-local files.
- **SOLID:** Asclepius keeps separate responsibilities for model catalog
  loading, process launch, provider auth helpers, and smoke checks.
  Provider/model sections are data-driven so adding a route should not require
  renderer rewrites.
- **Normal Form:** Workspace paths are canonicalized and converted to WSL paths
  before being handed to Hermes.
- **E2E:** `Test-Asclepius.ps1` keeps the critical path small but meaningful:
  syntax checks, real-Codex launcher dry-run, shortcut target, default Codex
  profile observation, window identity repair, and package hygiene.
- **WCAG / POUR / PE:** The normal user-facing UI is Codex Desktop itself. Any
  Asclepius surface is reserved for supervisor-only needs.

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

If Codex, WSL Ubuntu, Hermes, or Python are missing, Asclepius shows a minimal
supervisor setup surface with install buttons instead of pretending to be Codex.

## Install

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexNousCloud.ps1
```

Then open `asclepius.lnk` from the desktop. It opens the Asclepius provider
preflight screen first. After you choose a route, it launches the real signed
Codex Desktop app with the isolated Hermes-backed config.

If Nous OAuth login is needed, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-HermesNousOAuthLogin.ps1
```

## Provider Auth

Nous free models use Hermes OAuth by default. No Nous API key is required for
free Nous routes.

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
The smoke harness also scans the redistributable package for auth files,
credential stores, tokens, cookies, private keys, and common API-key formats.

To run the opt-in identity smoke that opens a fresh isolated Codex window and
labels only that new window as Asclepius:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AsclepiusCodexIdentitySmoke.ps1
```
