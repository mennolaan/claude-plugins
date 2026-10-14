#!/usr/bin/env bash
# pr-quiz grader. PostToolUse on AskUserQuestion.
# Grades the developer's real answers (tool_response.answers, keyed by question
# text) against the frozen key. At round end it reports the result to Claude
# and writes the pass record when every topic is correct. Only this hook
# writes a pass.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

say() { prq_context PostToolUse "$1"; exit 0; }

prq_read_input
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PRQ_IN" | jq -e "$PRQ_IS_QUIZ" >/dev/null 2>&1 || exit 0
helper="${CLAUDE_PLUGIN_ROOT:-${here}/..}/skills/quiz/scripts/pr-quiz"

cwd="$(prq_field '.cwd')"
prq_repo_ctx "${cwd:-$PWD}" || say "pr-quiz ERROR: no answer was graded, because ${cwd} is not a git checkout."
round="${PRQ_STATE}/round.json"
[ -f "$round" ] || say "pr-quiz ERROR: no answer was graded, because no quiz round is open for branch ${PRQ_BRANCH}."
n="$(jq -r .round "$round")"
keyfile="${PRQ_STATE}/key-${n}.json"
[ -f "$keyfile" ] || say "pr-quiz ERROR: no answer was graded, because the key of round ${n} is missing. Run ${helper} reset and start again."
[ "$(git hash-object "$keyfile")" = "$(jq -r '.key_sha // ""' "$round")" ] \
  || say "pr-quiz ERROR: no answer was graded, because the key of round ${n} changed after the first question. Run ${helper} reset and start a new quiz."

graded="$(printf '%s' "$PRQ_IN" | jq -c --slurpfile key "$keyfile" --arg idk "$PRQ_IDK" '
  .tool_response as $r
  | ($r.afkTimeoutMs != null) as $afk
  | (($r.followUp // false) == true) as $fu
  | ($r.answers // {}) as $ans
  | [ .tool_input.questions[] as $q
      | ($key[0].questions | map(select(.question == $q.question)) | first) as $k
      | select($k != null)
      | $ans[$q.question] as $a
      | { key: $q.question,
          value: { topic: $k.topic, answer: $a,
                   verdict: (if $afk then "timeout"
                             elif $fu then "followup"
                             elif ($a == null or $a == "") then "missing"
                             elif $a == $idk then "idk"
                             elif $a == $k.correct then "ok"
                             elif ($k.options | index($a)) != null then "wrong"
                             else "other" end) } } ]
  | from_entries')" || say "pr-quiz ERROR: no answer was graded (jq error on the tool response)."

updated="$(jq -c --argjson g "$graded" '.results += $g' "$round")" || say "pr-quiz ERROR: cannot update ${round}."
total="$(jq '.questions | length' "$keyfile")"
answered="$(printf '%s' "$updated" | jq --slurpfile key "$keyfile" '[.results | keys[] as $t | select($key[0].questions | any(.question == $t))] | length')"

if [ "$answered" -lt "$total" ]; then
  printf '%s' "$updated" | prq_write_json "$round" || say "pr-quiz ERROR: cannot update ${round}."
  say "pr-quiz: round ${n} progress: ${answered} of ${total} questions answered. Ask the remaining questions now. Do not tell the developer any result before the round is complete."
fi

report="$(printf '%s' "$updated" | jq -r --slurpfile key "$keyfile" --arg idk "$PRQ_IDK" '
  .results as $res
  | [ $key[0].questions | to_entries[] | .value as $k | ($res[$k.question]) as $g
      | select($g.verdict != "ok")
      | "Q\(.key + 1) [\($k.topic)]: \($k.question)\n  Developer answer: \(
           if $g.verdict == "idk" then "I don'"'"'t know (explain the whole topic)"
           elif $g.verdict == "timeout" then "none (the question timed out)"
           elif $g.verdict == "followup" or $g.verdict == "missing" then "none"
           elif $g.verdict == "other" then "free text: \($g.answer)"
           else $g.answer end)\n  Correct answer: \($k.correct)\n  Why: \($k.explanation)\n  Evidence: \($k.evidence)" ]
  | join("\n\n")')"
failed="$(printf '%s' "$updated" | jq -c --slurpfile key "$keyfile" '[.results as $res | $key[0].questions[] | select($res[.question].verdict != "ok") | .topic] | unique')"
nfail="$(printf '%s' "$failed" | jq 'length')"
correct=$((total - nfail))

if [ "$nfail" -eq 0 ]; then
  base="$(jq -r .base "$round")"; base_ref="$(jq -r .base_ref "$round")"; head="$(jq -r .head "$round")"
  pid="$(prq_patch_id "$base_ref" "$head")" || say "pr-quiz ERROR: all answers are correct, but the pass was not written: no merge base of ${base_ref} and ${head:0:7}."
  printf '%s' "$updated" | jq --arg pid "$pid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repo, branch, base, head, patch_id:$pid, rounds:.round, at:$at,
      history:(.history + [{round:.round, total:(.results | length), correct:(.results | length), failed:[]}])}' \
    | prq_write_json "${PRQ_STATE}/pass.json" || say "pr-quiz ERROR: all answers are correct, but ${PRQ_STATE}/pass.json was not written."
  rm -f "$round" "${PRQ_STATE}"/key-*.json
  scores="$(jq -r '[.history[] | "round \(.round) \(.correct)/\(.total)"] | join(", ")' "${PRQ_STATE}/pass.json")"
  # systemMessage reaches the developer directly; additionalContext reaches Claude.
  jq -cn --arg c "pr-quiz: PASS. Round ${n}: ${correct} of ${total} correct, so every topic is now correct. Scores: ${scores}. The PR gate is open for branch ${PRQ_BRANCH} at ${head:0:7} (base ${base}). Tell the developer the result and the scores. If a PR command was blocked before the quiz, run it again now." \
    --arg m "🎆 PR quiz passed! ${PRQ_BRANCH} at ${head:0:7}. Scores: ${scores}. The PR gate is open. 🎉" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  exit 0
fi

printf '%s' "$updated" | jq --argjson failed "$failed" --argjson total "$total" --argjson correct "$correct" \
  '.status = "done" | .failed = $failed | .history += [{round:.round, total:$total, correct:$correct, failed:$failed}]' \
  | prq_write_json "$round" || say "pr-quiz ERROR: cannot update ${round}."
say "pr-quiz: round ${n} result: ${correct} of ${total} correct. Failed topics: $(printf '%s' "$failed" | jq -r 'join(", ")').

Do these steps now, in this order:
1. Show the developer the score.
2. Explain every failed question below: the correct answer, why it is correct, and the code at the evidence location (give the path:line). For an \"I don't know\" answer, explain the whole topic from the code, not only this question. Do not skip a failed question.
3. Ask the developer with AskUserQuestion (a normal question, with no Q header) whether to retry now with ${nfail} new question(s), one for each failed topic.
4. On yes: run ${helper} start. Write one new question for each failed topic, with new wording and a new angle. Register it with ${helper} key, then ask it with the header \"R$((n + 1)) Q1/${nfail}\" and so on.

${report}"
