# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=claude
# HERDR_INTEGRATION_VERSION=10

param([string]$Action = "")

if ($Action -ne "session" -and $Action -ne "bgtrack") { exit 0 }
if ($env:HERDR_ENV -ne "1") { exit 0 }
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) { exit 0 }

$inputText = [Console]::In.ReadToEnd()
try {
    $payload = if ([string]::IsNullOrWhiteSpace($inputText)) { $null } else { $inputText | ConvertFrom-Json }
} catch {
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($payload.agent_id)) { exit 0 }

$eventName = "$($payload.hook_event_name)"

function Get-BgFlagPath {
    $safe = ($env:HERDR_PANE_ID -replace '[^0-9A-Za-z]', '_')
    return (Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-claude-bgpending-" + $safe))
}

function Clear-BgFlag {
    try { Remove-Item -Force -ErrorAction SilentlyContinue (Get-BgFlagPath) } catch {}
}

function Report-State([string]$State) {
    $seq = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try {
        & herdr @(
            "pane", "report-agent", $env:HERDR_PANE_ID,
            "--source", "herdr:claude", "--agent", "claude",
            "--state", $State, "--seq", "$seq"
        ) 2>$null | Out-Null
    } catch {}
}

function Get-WtdirFlagPath {
    $safe = ($env:HERDR_PANE_ID -replace '[^0-9A-Za-z]', '_')
    return (Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-claude-wtdir-" + $safe))
}

function Clear-WtdirFlag {
    try { Remove-Item -Force -ErrorAction SilentlyContinue (Get-WtdirFlagPath) } catch {}
}

function Get-HerdrRequestId {
    $millis = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rand = Get-Random -Minimum 0 -Maximum 1000000
    return ("herdr:claude:{0}:{1:D6}" -f $millis, $rand)
}

function Send-HerdrRequest($Request) {
    # Posts a single newline-terminated JSON request over the same socket the
    # `herdr` CLI itself connects to (HERDR_SOCKET_PATH), mirroring the .sh
    # hook's raw-socket `send()`. On Windows that path is a named pipe at
    # \\.\pipe\<HERDR_SOCKET_PATH>. Best-effort/fire-and-forget: never throws,
    # never blocks longer than the connect timeout, and does not wait for a
    # response.
    if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) { return }
    $pipe = $null
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
            ".", $env:HERDR_SOCKET_PATH, [System.IO.Pipes.PipeDirection]::InOut
        )
        $pipe.Connect(500)
        $json = (($Request | ConvertTo-Json -Compress -Depth 5) + "`n")
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
    } catch {
    } finally {
        if ($pipe) { try { $pipe.Dispose() } catch {} }
    }
}

function Report-Activity([string]$Kind, [string]$DirPath) {
    $reportParams = [ordered]@{
        pane_id = $env:HERDR_PANE_ID
        source  = "herdr:claude"
        kind    = $Kind
    }
    if ($null -ne $DirPath) { $reportParams["dir"] = $DirPath }
    Send-HerdrRequest ([ordered]@{
        id     = (Get-HerdrRequestId)
        method = "pane.report_agent_activity"
        params = $reportParams
    })
}

function Report-ActivityPath([string]$DirPath) {
    # Dedup consecutive identical dirs within a turn to limit socket traffic.
    # The flag is cleared at turn boundaries so a new turn always re-reports.
    $path = Get-WtdirFlagPath
    $last = $null
    if (Test-Path $path) {
        try { $last = Get-Content -Path $path -Raw -ErrorAction Stop } catch { $last = $null }
    }
    if ($last -eq $DirPath) { return }
    try { Set-Content -Path $path -Value $DirPath -NoNewline -ErrorAction Stop } catch {}
    Report-Activity "path" $DirPath
}

# Background-task tracking. Claude sets an identical idle terminal title whether a
# turn is finished or has ended with a run_in_background/Monitor task still
# pending, so keep the pane "working" while one is outstanding rather than showing
# a done checkmark. herdr's reserved-source handler turns these working/idle
# reports into a background-pending hint; screen detection still owns base state.
if ($Action -eq "bgtrack") {
    if ($eventName -eq "PreToolUse") {
        $tool = "$($payload.tool_name)"
        $bg = $false
        if ($payload.tool_input -and $payload.tool_input.run_in_background) { $bg = [bool]$payload.tool_input.run_in_background }
        if ($tool -eq "Monitor" -or $bg) {
            try { New-Item -ItemType File -Force -Path (Get-BgFlagPath) | Out-Null } catch {}
            Report-State "working"
        }
        if ($tool -in @("Edit", "Write", "Read", "NotebookEdit")) {
            $filePath = $null
            if ($payload.tool_input.file_path) { $filePath = "$($payload.tool_input.file_path)" }
            elseif ($payload.tool_input.notebook_path) { $filePath = "$($payload.tool_input.notebook_path)" }
            if (-not [string]::IsNullOrWhiteSpace($filePath)) {
                Report-ActivityPath (Split-Path -Parent $filePath)
            }
        }
    } elseif ($eventName -eq "UserPromptSubmit") {
        Report-Activity "turn_start"
        Clear-WtdirFlag
        $prompt = "$($payload.prompt)"
        if ($prompt -like "*<task-notification>*" -and $prompt -like "*<event>*") {
            # Intermediate event from a still-running Monitor (e.g. a CI pipeline
            # emitting progress): the task is not done, so keep the flag set.
            try { New-Item -ItemType File -Force -Path (Get-BgFlagPath) | Out-Null } catch {}
        } else {
            # Real user prompt, run_in_background completion, or Monitor stream-end.
            Clear-BgFlag
        }
    } elseif ($eventName -eq "Stop") {
        Report-Activity "turn_end"
        Clear-WtdirFlag
        if (Test-Path (Get-BgFlagPath)) { Report-State "working" } else { Report-State "idle" }
    }
    exit 0
}

# $Action -eq "session": link the pane to the Claude session for resume/tracking.
if ($eventName -eq "SessionStart") {
    Clear-BgFlag
    Report-Activity "reset"
    Clear-WtdirFlag
}
if ($eventName -eq "SubagentStop") { exit 0 }

$sessionId = $payload.session_id
if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

$seq = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
try {
    $args = @(
        "pane",
        "report-agent-session",
        $env:HERDR_PANE_ID,
        "--source",
        "herdr:claude",
        "--agent",
        "claude",
        "--seq",
        "$seq",
        "--agent-session-id",
        "$sessionId"
    )
    if ($payload.transcript_path -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.transcript_path)) {
        $args += @("--agent-session-path", "$($payload.transcript_path)")
    }
    if ($payload.hook_event_name -eq "SessionStart" -and $payload.source -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.source)) {
        $args += @("--session-start-source", "$($payload.source)")
    }
    & herdr @args 2>$null | Out-Null
} catch {
}
