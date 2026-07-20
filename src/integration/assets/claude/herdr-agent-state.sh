#!/bin/sh
# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=claude
# HERDR_INTEGRATION_VERSION=9

set -eu

action="${1:-}"
hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-claude-hook.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

case "$action" in
  session|bgtrack) ;;
  *) exit 0 ;;
esac

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# This runs as a PreToolUse/Stop/UserPromptSubmit hook, so it must never fail the
# tool: the python body is fully guarded and the script always exits 0.
HERDR_ACTION="$action" HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY' || true
import json
import os
import random
import socket
import tempfile
import time


def run():
    source = "herdr:claude"
    action = os.environ.get("HERDR_ACTION", "")
    pane_id = os.environ.get("HERDR_PANE_ID")
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    hook_input_file = os.environ.get("HERDR_HOOK_INPUT_FILE")

    if not pane_id or not socket_path:
        return

    hook_input = {}
    if hook_input_file:
        try:
            with open(hook_input_file, encoding="utf-8") as handle:
                content = handle.read()
            if content.strip():
                hook_input = json.loads(content)
        except Exception:
            hook_input = {}

    hook_event_name = str(hook_input.get("hook_event_name") or "")
    if hook_input.get("agent_id"):
        # Subagent lifecycle events must never move the main pane state.
        return

    def send(request):
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.5)
            client.connect(socket_path)
            client.sendall((json.dumps(request) + "\n").encode())
            try:
                client.recv(4096)
            except Exception:
                pass
            client.close()
        except Exception:
            pass

    def request_id():
        return f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"

    def report_state(state):
        send({
            "id": request_id(),
            "method": "pane.report_agent",
            "params": {
                "pane_id": pane_id,
                "source": source,
                "agent": "claude",
                "state": state,
                "seq": time.time_ns(),
            },
        })

    def bgflag_path():
        safe = "".join(c if c.isalnum() else "_" for c in pane_id)
        return os.path.join(tempfile.gettempdir(), "herdr-claude-bgpending-" + safe)

    def bgflag_clear():
        try:
            os.remove(bgflag_path())
        except OSError:
            pass

    def report_activity(kind, dir_path=None):
        params = {"pane_id": pane_id, "source": source, "kind": kind}
        if dir_path is not None:
            params["dir"] = dir_path
        send({
            "id": request_id(),
            "method": "pane.report_agent_activity",
            "params": params,
        })

    def wtdir_flag_path():
        safe = "".join(c if c.isalnum() else "_" for c in pane_id)
        return os.path.join(tempfile.gettempdir(), "herdr-claude-wtdir-" + safe)

    def wtdir_flag_clear():
        try:
            os.remove(wtdir_flag_path())
        except OSError:
            pass

    def report_activity_path(dir_path):
        # Dedup consecutive identical dirs within a turn to limit socket traffic.
        # The flag is cleared at turn boundaries so a new turn always re-reports.
        path = wtdir_flag_path()
        try:
            with open(path, encoding="utf-8") as handle:
                last = handle.read()
        except OSError:
            last = ""
        if last == dir_path:
            return
        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(dir_path)
        except OSError:
            pass
        report_activity("path", dir_path)

    # Background-task tracking. Claude sets an identical idle terminal title
    # whether a turn is finished or has ended with a run_in_background/Monitor
    # task still pending, so herdr cannot tell "done" from "waiting on a task"
    # from the screen. We remember outstanding tasks in a per-pane flag file and
    # report `working` at Stop while one is pending, so a waiting session is not
    # shown as a done checkmark. herdr's reserved-source handler turns these
    # working/idle reports into a background-pending hint (screen detection still
    # owns the base state).
    if action == "bgtrack":
        if hook_event_name == "PreToolUse":
            tool = str(hook_input.get("tool_name") or "")
            tool_input = hook_input.get("tool_input")
            if not isinstance(tool_input, dict):
                tool_input = {}
            if tool == "Monitor" or bool(tool_input.get("run_in_background")):
                try:
                    open(bgflag_path(), "w").close()
                except OSError:
                    pass
                report_state("working")
            if tool in ("Edit", "Write", "Read", "NotebookEdit"):
                file_path = tool_input.get("file_path") or tool_input.get("notebook_path")
                if isinstance(file_path, str) and file_path:
                    report_activity_path(os.path.dirname(file_path))
        elif hook_event_name == "UserPromptSubmit":
            report_activity("turn_start")
            wtdir_flag_clear()
            prompt = str(hook_input.get("prompt") or "")
            if "<task-notification>" in prompt and "<event>" in prompt:
                # An intermediate event from a still-running Monitor (e.g. a CI
                # pipeline emitting progress). The task is NOT done, so keep the
                # pane marked as waiting; a Monitor emits <event> per update and
                # only carries <status> when the stream ends.
                try:
                    open(bgflag_path(), "w").close()
                except OSError:
                    pass
            else:
                # A real user prompt, a run_in_background completion, or a
                # Monitor stream-end: the awaited task returned (or the user took
                # over). Clear the flag; the next Stop reports idle unless another
                # task is still armed.
                bgflag_clear()
        elif hook_event_name == "Stop":
            report_activity("turn_end")
            wtdir_flag_clear()
            if os.path.exists(bgflag_path()):
                report_state("working")
            else:
                report_state("idle")
        return

    # action == "session": link the pane to the Claude session for resume.
    if hook_event_name == "SessionStart":
        # Fresh/resumed/cleared session: clean background-task and worktree slate.
        bgflag_clear()
        report_activity("reset")
        wtdir_flag_clear()
    if hook_event_name == "SubagentStop":
        # SubagentStop is a completion event. Older Herdr integrations mapped it
        # to durable working, but Claude recap/away-summary can emit it after the
        # main turn has already stopped. Never let it revive an idle pane.
        return

    session_id = hook_input.get("session_id")
    agent_session_id = session_id if isinstance(session_id, str) and session_id else None
    transcript_path = hook_input.get("transcript_path")
    agent_session_path = (
        transcript_path if isinstance(transcript_path, str) and transcript_path else None
    )
    session_start_source = (
        hook_input.get("source") if hook_event_name == "SessionStart" else None
    )
    if not isinstance(session_start_source, str) or not session_start_source:
        session_start_source = None
    if not agent_session_id:
        return

    params = {
        "pane_id": pane_id,
        "source": source,
        "agent": "claude",
        "seq": time.time_ns(),
        "agent_session_id": agent_session_id,
    }
    if agent_session_path:
        params["agent_session_path"] = agent_session_path
    if session_start_source:
        params["session_start_source"] = session_start_source
    send({
        "id": request_id(),
        "method": "pane.report_agent_session",
        "params": params,
    })


try:
    run()
except Exception:
    pass
PY

exit 0
