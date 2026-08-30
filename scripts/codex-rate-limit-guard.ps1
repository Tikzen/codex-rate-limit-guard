[CmdletBinding()]
param(
    [int]$MaxRetries = -1,
    [int]$CooldownSeconds = -1,
    [int]$MaxCooldownSeconds = 900,
    [int]$PollMilliseconds = 250,
    [string]$CodexPath = 'codex',
    [string]$ErrorCodes = '',
    [switch]$KillProcessTree,
    [switch]$NoPrompt,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs
)

$ErrorActionPreference = 'Stop'

function Convert-ToPositiveInt {
    param(
        [string]$Value,
        [int]$Default,
        [int]$Minimum = 0
    )

    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed) -and $parsed -ge $Minimum) {
        return $parsed
    }
    return $Default
}

function Get-DescendantProcessIds {
    param([int]$RootId)

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootId" -ErrorAction SilentlyContinue)
    $ids = @()
    foreach ($child in $children) {
        $ids += [int]$child.ProcessId
        $ids += Get-DescendantProcessIds -RootId ([int]$child.ProcessId)
    }
    return $ids
}

function Stop-ProcessTree {
    param([int]$RootId)

    $ids = @((Get-DescendantProcessIds -RootId $RootId) + $RootId) | Select-Object -Unique
    foreach ($id in ($ids | Sort-Object -Descending)) {
        try {
            Stop-Process -Id $id -Force -ErrorAction Stop
        }
        catch {
            # The process may have exited between discovery and termination.
        }
    }
}

function Test-TransientFailure {
    param(
        [string]$Text,
        [int[]]$RetryCodes
    )

    $codePattern = '\b(?:' + (($RetryCodes | ForEach-Object { [string]$_ }) -join '|') + ')\b'
    if ($Text -match "(?i)$codePattern") {
        return $true
    }
    if (($RetryCodes -contains 429) -and $Text -match '(?i)(?:too many requests|rate[ -]?limit|rpm limit|requests per minute)') {
        return $true
    }
    if (($RetryCodes | Where-Object { $_ -ge 500 -and $_ -le 599 }) -and $Text -match '(?i)(?:internal server error|temporar(?:y|ily) unavailable|server overloaded)') {
        return $true
    }
    return $false
}

function Convert-ToErrorCodeList {
    param([string]$Value)

    $default = @(429, 500, 502, 503, 504)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $default
    }

    $codes = @()
    foreach ($part in ($Value -split ',')) {
        $trimmed = $part.Trim()
        $parsed = 0
        if (-not [int]::TryParse($trimmed, [ref]$parsed) -or $parsed -lt 100 -or $parsed -gt 599) {
            throw "Invalid error code '$trimmed'. Use comma-separated HTTP status codes, for example: 429,500"
        }
        if ($codes -notcontains $parsed) {
            $codes += $parsed
        }
    }
    if ($codes.Count -eq 0) {
        return $default
    }
    return $codes
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-RequestedWorkingDirectory {
    param([string[]]$Arguments)

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -in @('-C', '--cd') -and ($index + 1) -lt $Arguments.Count) {
            return $Arguments[$index + 1]
        }
        if ($Arguments[$index] -like '--cd=*') {
            return $Arguments[$index].Substring(5)
        }
    }
    return (Get-Location).Path
}

if (-not $CodexArgs -or $CodexArgs.Count -eq 0) {
    throw 'Pass Codex arguments after --, for example: -- exec "your task"'
}

if ($CodexArgs[0] -eq '--') {
    $CodexArgs = @($CodexArgs | Select-Object -Skip 1)
}

if (-not $CodexArgs -or $CodexArgs[0] -ne 'exec') {
    throw 'The guard currently supports codex exec runs only. Start the command with: -- exec'
}

if (-not $NoPrompt -and [string]::IsNullOrWhiteSpace($ErrorCodes)) {
    $ErrorCodes = Read-Host 'Retry error codes [429,500,502,503,504]'
}
$retryCodes = Convert-ToErrorCodeList -Value $ErrorCodes

if (-not $NoPrompt -and $MaxRetries -lt 0) {
    $MaxRetries = Convert-ToPositiveInt -Value (Read-Host 'Maximum retries [8]') -Default 8
}
elseif ($MaxRetries -lt 0) {
    $MaxRetries = 8
}

if (-not $NoPrompt -and $CooldownSeconds -lt 0) {
    $CooldownSeconds = Convert-ToPositiveInt -Value (Read-Host 'Initial cooldown seconds [60]') -Default 60 -Minimum 1
}
elseif ($CooldownSeconds -lt 0) {
    $CooldownSeconds = 60
}

if ($MaxCooldownSeconds -lt $CooldownSeconds) {
    $MaxCooldownSeconds = $CooldownSeconds
}

$workingDirectory = Get-RequestedWorkingDirectory -Arguments $CodexArgs
if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
    throw "Codex working directory does not exist: $workingDirectory"
}
$workingDirectory = (Resolve-Path -LiteralPath $workingDirectory).Path
$attempt = 0
$retryCount = 0
$lastExitCode = 1

while ($true) {
    $attempt++
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-rate-limit-guard-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $stdoutPath = Join-Path $tempRoot 'stdout.log'
    $stderrPath = Join-Path $tempRoot 'stderr.log'

    Write-Host ("[guard] attempt {0}: codex {1}" -f $attempt, (($CodexArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '))

    $process = Start-Process -FilePath $CodexPath `
        -ArgumentList $CodexArgs `
        -WorkingDirectory $workingDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $detectedTransient = $false
    $announcedTransient = $false

    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds $PollMilliseconds
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if ($text -and (Test-TransientFailure -Text $text -RetryCodes $retryCodes)) {
                $detectedTransient = $true
                if (-not $announcedTransient) {
                    Write-Warning '[guard] transient 429/500/rate-limit signal detected; waiting for Codex to exit.'
                    $announcedTransient = $true
                }
            }
        }
        if ($detectedTransient -and $KillProcessTree) {
            Write-Warning '[guard] -KillProcessTree was supplied; stopping the Codex process tree.'
            Stop-ProcessTree -RootId $process.Id
            break
        }
        $process.Refresh()
    }

    if (-not $process.HasExited) {
        try { $process.WaitForExit(5000) | Out-Null } catch { }
    }

    if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath }
    if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ }
    }

    $lastExitCode = if ($process.HasExited) { $process.ExitCode } else { 1 }
    $combined = ''
    if (Test-Path -LiteralPath $stdoutPath) { $combined += Get-Content -LiteralPath $stdoutPath -Raw }
    if (Test-Path -LiteralPath $stderrPath) { $combined += "`n" + (Get-Content -LiteralPath $stderrPath -Raw) }
    $detectedTransient = $detectedTransient -or (Test-TransientFailure -Text $combined -RetryCodes $retryCodes)

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

    if (-not $detectedTransient -or $retryCount -ge $MaxRetries) {
        if ($detectedTransient -and $retryCount -ge $MaxRetries) {
            Write-Warning ("[guard] retry limit reached ({0}); exiting with code {1}." -f $MaxRetries, $lastExitCode)
        }
        exit $lastExitCode
    }

    $retryCount++
    $delay = [Math]::Min($MaxCooldownSeconds, [int][Math]::Max(1, $CooldownSeconds * [Math]::Pow(2, $retryCount - 1)))
    Write-Warning ("[guard] waiting {0}s before resume attempt {1}/{2}." -f $delay, $retryCount, $MaxRetries)
    Start-Sleep -Seconds $delay

    $CodexArgs = @('exec', 'resume', '--last')
}
