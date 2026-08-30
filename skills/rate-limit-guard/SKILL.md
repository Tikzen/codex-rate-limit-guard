---
name: rate-limit-guard
description: Run Codex CLI work under a retry supervisor for transient 429/500 and RPM-limit failures.
---

# Codex Rate Limit Guard

This plugin provides an external supervisor for **Codex CLI**. It cannot intercept the current
Codex App conversation's internal HTTP request; use it when starting a CLI `codex exec` run.

## Windows usage

From PowerShell:

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" -- exec -C "D:\repo" "Finish the task and run tests"
```

The script asks for retryable HTTP status codes, maximum retry count, and cooldown unless values are supplied:

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -ErrorCodes "429,500" -MaxRetries 8 -CooldownSeconds 60 -MaxCooldownSeconds 600 `
  -- exec --json "Finish the task and run tests"
```

The default retry codes are `429,500,502,503,504`. Set `-ErrorCodes` to any comma-separated HTTP
status codes from `100` through `599`, for example `-ErrorCodes "429,500"`.

When a run exits with a recognized transient failure (`429`, `500`, `rate limit`, `RPM`, or
`internal server error`), the supervisor waits with exponential backoff and runs
`codex exec resume --last`. By default it lets Codex exit on its own and
does not kill child processes. Pass `-KillProcessTree` only when a run is genuinely stuck.

Use `-NoPrompt` in automation. Set `-MaxRetries 0` to disable retries after the first run, or use
`-MaxRetries -1` (the default) to ask interactively.

## Important boundary

This is a process supervisor, not an in-process network interceptor. It protects CLI runs that are
started through the script. Codex App sessions already running in the desktop UI are outside the
plugin's process boundary.
