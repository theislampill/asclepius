# Asclepius Regression Andon

This repo is for Asclepius / Cloud-Codex: a launcher and isolated profile that
selects a cloud route first, then opens the real signed Codex Desktop app with
Hermes underneath. It is not a fake Codex UI, not a Codex binary patch, and not
a wrapper that should disturb the user's normal Codex session.

## Stop Conditions

- If Alt-Tab, taskbar identity, login state, or the provider launcher chrome
  regresses, stop launching repeated windows. Inspect process/HWND state first.
- Do not kill, rename, patch, inject into, or reconfigure the user's normal
  Codex session unless the user explicitly asks.
- Never print or package credentials, cookies, Electron state, `auth.json`,
  tokens, API keys, or `cloud-secrets.json`.

## Window Identity Rules

- The visible Codex window can belong to the root `Codex.exe` process while the
  Asclepius `--user-data-dir` marker lives on child Electron processes.
- Therefore, never rely only on `Get-Process.MainWindowHandle` or only on the
  visible process command line to decide whether a Codex window is Asclepius.
- Build the Codex process family from CIM `ProcessId` and `ParentProcessId`.
  If any child process has user data exactly matching:

  ```text
  %USERPROFILE%\.codex-nous-cloud\electron-user-data
  ```

  then its Codex ancestors are the Asclepius family and may be branded.
- Brand only the Asclepius family with:
  - title: `Asclepius`
  - AppUserModelID: `NousResearch.Asclepius.Codex`
- Do not brand the normal Codex family, typically using `%APPDATA%` or
  `AppData\Local\Packages\OpenAI.Codex_*\LocalCache\Roaming\Codex`.
- Use `Start-AsclepiusWindowIdentityWatcher.ps1`; it enumerates top-level HWNDs
  for the target PID and repairs title/AppUserModelID after Codex resets them.

## Provider Launcher Rules

- `asclepius.lnk` opens `Launch-AsclepiusProviderLauncher.vbs`.
- The provider launcher is a preflight screen. Real Codex should not open until
  the user chooses a provider/model route and clicks launch.
- The provider launcher should look Codex-adjacent, not like legacy Windows UI:
  custom dark chrome, no native white title strip, no picker drawn over Codex.
- Keep the launcher chrome dark using `WindowStyle=None`, local title buttons,
  and DWM dark border/caption attributes. Avoid native resizable WPF chrome if
  it brings back the white top edge.
- The launcher is not resizable or maximizable. Do not restore the native
  maximize button or double-click-to-maximize behavior.
- The refresh control is an icon button. Hermes update state belongs beside it:
  show `Hermes up to date` when current and an explicit `Update Hermes` chip
  with version/commit-behind detail when outdated.

## Hermes Update Overlay Rules

- A Codex titlebar update chip must be an external Asclepius-owned overlay
  anchored to the Asclepius Codex HWND. Do not inject into Codex, edit memory,
  patch files under WindowsApps, or hijack Codex's own blue update button.
- The overlay may open `Update-HermesGolden.ps1` and refresh status while Codex
  stays open. It must hide when Hermes is current, the target Codex window is
  minimized, or the target Codex window is not foreground.
- Start the overlay only after the isolated Asclepius Codex PID/HWND is found.
  Never target the user's normal Codex session.

## Context And Tool Visibility Rules

- The context window shown to the user must be the Codex-usable window that
  drives Codex UI accounting and auto-compaction, not only the provider's raw
  model maximum.
- Keep the generated status files authoritative for completed turns:
  `%USERPROFILE%\.codex-nous-cloud\asclepius-context-status.md` and `.json`.
- Hermes tool execution happens inside Hermes. When
  `asclepius_hermes_event_runner.py` is enabled, the Windows bridge translates
  Hermes callback events into Codex-compatible `function_call` /
  `function_call_output` stream items.
- If the event runner is unavailable or fails, the bridge may fall back to the
  old CLI path. In that path, do not pretend native live widgets are present.
- Surface Hermes tool activity from Hermes logs in the Asclepius context status
  so the model can answer what tools ran after completion.
- A currently in-flight turn is not final until Hermes logs usage; do not fill
  the context meter with guessed final values.

## Auth And Packaging Rules

- The installed local profile may link or seed auth from the user's existing
  signed-in Codex installation at launch time.
- The redistributable package must never include generated state:
  `codex-home/`, `electron-user-data/`, `logs/`, `auth.json`,
  `cloud-secrets.json`, cookies, tokens, keys, or runtime logs.
- If Electron auth state is locked by a running Codex session, report the local
  sync as partial rather than killing Codex.

## Smoke Checklist

- Run syntax checks and `Test-Asclepius.ps1` after launcher or identity changes.
- For live identity smoke, launch or focus only the isolated Asclepius profile,
  then verify:
  - Asclepius Codex root PID title is `Asclepius`.
  - Normal Codex root PID title remains `Codex`.
  - AppUserModelID is `NousResearch.Asclepius.Codex` on the Asclepius HWND.
- Use process tree/HWND enumeration to verify; do not trust a single
  `MainWindowHandle` field.

## PowerShell Footguns Already Hit

- `$PID` is read-only; use `$procId` or another variable name.
- Do not pipe directly after complex `foreach` blocks; assign to `$rows` first.
- `Add-Type` needs `-TypeDefinition`; do not pipe a here-string into it.
- Here-strings must have opening and closing markers alone on their own lines.
- Do not run multiple WSL/Hermes probes in parallel. WSL has produced
  `Wsl/Service/E_UNEXPECTED` and timeout failures under concurrent probes, so
  keep WSL reads/smokes sequential even when other local PowerShell reads can
  run in parallel.
