#!/usr/bin/env bash
# pr-quiz question check. PreToolUse on AskUserQuestion.
# A quiz call must match the registered key of the open round exactly, offer
# the "I don't know" option, and carry no prefilled answers. The first quiz
# call of a round freezes the key (its git blob id goes into the round state).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

prq_read_input
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PRQ_IN" | jq -e "$PRQ_IS_QUIZ" >/dev/null 2>&1 || exit 0
prq_require_tools

cwd="$(prq_field '.cwd')"
prq_repo_ctx "${cwd:-$PWD}" || prq_deny "pr-quiz: the quiz runs outside a git checkout (${cwd}). Run the quiz from the checkout of the PR branch."
[ -n "$PRQ_BRANCH" ] || prq_deny "pr-quiz: HEAD is detached. Check out the PR branch, then start the quiz."
round="${PRQ_STATE}/round.json"
helper="${CLAUDE_PLUGIN_ROOT:-${here}/..}/skills/quiz/scripts/pr-quiz"
[ -f "$round" ] || prq_deny "pr-quiz: no quiz round is open for branch ${PRQ_BRANCH}. Run ${helper} start, then register a key with ${helper} key, then ask."

status="$(jq -r .status "$round")"; n="$(jq -r .round "$round")"
case "$status" in
  keyed|asking) ;;
  keyless) prq_deny "pr-quiz: round ${n} has no answer key. Register it with ${helper} key before you ask." ;;
  done) prq_deny "pr-quiz: round ${n} is complete. Register the retry key with ${helper} key before you ask." ;;
  *) prq_deny "pr-quiz: round state ${status} is not known. Run ${helper} reset." ;;
esac
[ "$(jq -r .head "$round")" = "$PRQ_HEAD" ] || prq_deny "pr-quiz: HEAD moved to ${PRQ_HEAD:0:7} after the quiz started. Run ${helper} start again."

keyfile="${PRQ_STATE}/key-${n}.json"
[ -f "$keyfile" ] || prq_deny "pr-quiz: the key file for round ${n} is missing. Run ${helper} reset, then start again."
sha="$(git hash-object "$keyfile")"
frozen="$(jq -r '.key_sha // ""' "$round")"
[ -z "$frozen" ] || [ "$frozen" = "$sha" ] || prq_deny "pr-quiz: the key of round ${n} changed after the first question. Run ${helper} reset and start a new quiz."

errs="$(printf '%s' "$PRQ_IN" | jq -r --slurpfile key "$keyfile" --slurpfile round "$round" --arg idk "$PRQ_IDK" '
  ($key[0].questions) as $kq | ($round[0].results) as $res
  | .tool_input as $in
  | [ (if ($in.answers // {} | length) > 0 or ($in.annotations // {} | length) > 0 or (($in.response // "") != "")
         then "the call carries prefilled answers. The developer must answer." else empty end),
      ( $in.questions[] as $q
        | ($kq | map(select(.question == $q.question)) | first) as $k
        | if $k == null then "question not in the round key: \($q.question)"
          else
            (if ($q.multiSelect // false) then "multiSelect must be false: \($q.question)" else empty end),
            (if ([$q.options[]?.label] | sort) != (($k.options + [$idk]) | sort)
               then "options must be the 3 key options plus \"\($idk)\", exactly: \($q.question)" else empty end),
            (if $res[$q.question] != null then "already answered in this round: \($q.question)" else empty end)
          end )
    ] | .[]')" || prq_deny "pr-quiz: cannot read the quiz call (jq error)."
[ -z "$errs" ] || prq_deny "pr-quiz: this quiz call does not match the key of round ${n}. Fix it and ask again:
${errs}"

jq --arg sha "$sha" --argjson asked "$(printf '%s' "$PRQ_IN" | jq '[.tool_input.questions[].question]')" '
  .status = "asking" | .key_sha = (if .key_sha == "" then $sha else .key_sha end) | .asked = ((.asked + $asked) | unique)' "$round" \
  | prq_write_json "$round" || prq_deny "pr-quiz: cannot update ${round}."
exit 0
