# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=claude
# HERDR_INTEGRATION_VERSION=8

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
    } elseif ($eventName -eq "UserPromptSubmit") {
        Clear-BgFlag
    } elseif ($eventName -eq "Stop") {
        if (Test-Path (Get-BgFlagPath)) { Report-State "working" } else { Report-State "idle" }
    }
    exit 0
}

# $Action -eq "session": link the pane to the Claude session for resume/tracking.
if ($eventName -eq "SessionStart") { Clear-BgFlag }
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
