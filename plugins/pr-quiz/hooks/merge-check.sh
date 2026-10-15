#!/usr/bin/env bash
# pr-quiz merge check trigger. PostToolUse on Bash and on MCP pull-request tools.
# After a push or a PR command, posts the pr-quiz/merge-check status when the
# switch is on and the pass covers HEAD (merge-check-lib.sh). Never blocks.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"
# shellcheck source=merge-check-lib.sh
. "${here}/merge-check-lib.sh"

prq_read_input
case "$PRQ_IN" in
  *push*|*pr*create*|*pr*new*|*pull-request*|*mcp__*) ;;
  *) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0
case "$(prq_field '.tool_name')" in
  Bash)
    cmd="$(prq_field '.tool_input.command')"
    case "$cmd" in
      *push*|*pr*create*|*pr*new*|*pull-request*) ;;
      *) exit 0 ;;
    esac
    ;;
  mcp__*repo_pull_request_write) [ "$(prq_field '.tool_input.action')" = create ] || exit 0 ;;
  mcp__*) ;;
  *) exit 0 ;;
esac
cwd="$(prq_field '.cwd')"
dir="${cwd:-$PWD}"; target=""
# Follow cd and pushd up to the push or PR command: "cd <checkout> && git push && cd .."
# posts for <checkout>.
if [ -n "${cmd:-}" ]; then
  while IFS= read -r -d $'\036' seg; do
    case "$seg" in *__PRQ_OPEN__*|*__PRQ_CLOSE__*) continue ;; esac
    split_words "$seg"
    [ ${#WORDS[@]} -gt 0 ] || continue
    case "${WORDS[0]}" in
      cd|pushd)
        [ ${#WORDS[@]} -ge 2 ] || continue
        t="${WORDS[1]}"
        case "$t" in \~) t="$HOME" ;; \~/*) t="${HOME}/${t#\~/}" ;; esac
        case "$t" in /*) ;; *) t="${dir}/${t}" ;; esac
        [ -d "$t" ] && dir="$(cd "$t" && pwd)"
        continue ;;
    esac
    case " ${WORDS[*]} " in *" push "*|*" pr "*|*" pull-request "*) target="$dir" ;; esac
  done < <(quoted_segments "$cmd")
fi
prq_repo_ctx "${target:-$dir}" || exit 0
prq_mc_run success
case "$PRQ_MC_RESULT" in
  posted|error)
    jq -cn --arg m "pr-quiz merge check: ${PRQ_MC_MSG}" \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' ;;
  notyet) prq_context PostToolUse "pr-quiz merge check: not posted yet: ${PRQ_MC_MSG}" ;;
esac
exit 0
