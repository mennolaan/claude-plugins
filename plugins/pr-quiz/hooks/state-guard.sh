#!/usr/bin/env bash
# pr-quiz state guard. PreToolUse on Write, Edit, MultiEdit, NotebookEdit and Bash.
# Denies direct access to the quiz state (<git dir>/pr-quiz), edits to the
# installed plugin, and CLI calls that disable or remove it. Claude reaches the
# state only through skills/quiz/scripts/pr-quiz. A guardrail, not a boundary.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

prq_read_input
case "$PRQ_IN" in *pr-quiz*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || prq_deny "pr-quiz: jq is not installed. Install jq."

tool="$(prq_field '.tool_name')"
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    path="$(prq_field '.tool_input.file_path // .tool_input.notebook_path')"
    case "$path" in
      */.git/*pr-quiz*|.git/*pr-quiz*) prq_deny "pr-quiz: ${path} is quiz state. Only the pr-quiz helper and hooks change it." ;;
      */.claude/plugins/*pr-quiz*) prq_deny "pr-quiz: ${path} belongs to an installed plugin. Change the plugin in its source repo, not in the install." ;;
    esac
    ;;
  Bash)
    cmd="$(prq_field '.tool_input.command')"
    # Drop helper invocations; what is left may not name the state or the install.
    rest="$(printf '%s' "$cmd" | sed -E 's#[^[:space:]"'"'"']*skills/quiz/scripts/pr-quiz([[:space:]]+(start|diff|key|status|reset))?##g')"
    case "$rest" in
      *pr-quiz*)
        case "$rest" in
          *.git/*|*git-dir*|*git-common-dir*) prq_deny "pr-quiz: this command reaches the quiz state directly. Use the helper (pr-quiz status, pr-quiz reset) instead." ;;
          *.claude/plugins*) prq_deny "pr-quiz: this command reaches the installed plugin files. Change the plugin in its source repo." ;;
        esac
        if printf '%s' "$rest" | grep -Eq 'claude[[:space:]]+plugins?[[:space:]]+(disable|uninstall|remove|rm)'; then
          prq_deny "pr-quiz: Claude may not disable or remove the pr-quiz plugin. The developer can do that with /plugin."
        fi
        ;;
    esac
    ;;
esac
exit 0
