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
- Refreshes a live provider/model/price catalog from Nous and OpenRouter.
- Shows provider-qualified model routes, for example:
  - `Nous Portal via Hermes OAuth | deepseek/deepseek-v4-flash`
  - `OpenRouter | deepseek/deepseek-v4-flash`
- Supports Hermes OAuth login for free Nous models.
- Supports optional direct provider API keys stored only in the installed local profile.

## What This Baseline Does Not Do Yet

This first packaged checkpoint uses Hermes for OAuth/proxy auth and model catalog
discovery. It does not yet route Codex turns through the full Hermes agent
runtime, memory, learning, skill, or session architecture.

The intended next architecture is:

```text
Codex-like app UX -> Hermes Agent runtime -> Hermes memory/skills/learning -> cloud model providers
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
