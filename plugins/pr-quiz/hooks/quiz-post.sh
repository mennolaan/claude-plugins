#!/usr/bin/env bash
# pr-quiz grader. PostToolUse on AskUserQuestion.
# Grades the developer's real answers (tool_response.answers, keyed by question
# text) against the frozen key. After each call it shows the developer which
# answers were wrong, without the correct answer, and explains every "I don't
# know" or free-text answer at once. At round end it reports the result. When
# every topic is correct it writes the pass record and gives a recap of the
# wrong answers. Only this hook writes a pass.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

say() { prq_context PostToolUse "$1"; exit 0; }
# tell <developer message> <Claude context>: the developer sees the first text directly.
tell() { jq -cn --arg m "$1" --arg c "$2" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'; exit 0; }

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

# This call's questions in key order, with the label the developer saw (Q3, or R2 Q1).
lp=""; [ "$n" -gt 1 ] && lp="R${n} "
batch="$(printf '%s' "$graded" | jq -c --slurpfile key "$keyfile" --arg lp "$lp" '
  . as $g | [ $key[0].questions | to_entries[] | select($g[.value.question] != null)
    | { label: "\($lp)Q\(.key + 1)", i: (.key + 1), question: .value.question, topic: .value.topic,
        correct: .value.correct, explanation: .value.explanation, evidence: .value.evidence,
        answer: $g[.value.question].answer, verdict: $g[.value.question].verdict } ]')" \
  || say "pr-quiz ERROR: no answer was graded (jq error on the key)."

# The developer's view of this call. A wrong or missing answer shows no correct answer.
devtext="$(printf '%s' "$batch" | jq -r --arg n "$n" '
  def none: .verdict == "timeout" or .verdict == "followup" or .verdict == "missing";
  def explain: .verdict == "idk" or .verdict == "other";
  if length == 0 then "pr-quiz round \($n): no question of this call is in the key." else
  [ "pr-quiz round \($n), questions \(first.i) to \(last.i): \(map(select(.verdict == "ok")) | length) of \(length) correct.",
    (map(select(.verdict == "wrong")) | if length > 0 then "Wrong: " + (map("\(.label) \"\(.question)\"") | join("; ")) + ". You get a new question on each in the next round, and the correct answer after you pass." else empty end),
    (map(select(none)) | if length > 0 then "No answer, so wrong: " + (map(.label + (if .verdict == "timeout" then " (the question timed out)" else "" end)) | join(", ")) + "." else empty end),
    (.[] | select(explain) | "Explained: \(.label) \"\(.question)\"\n  Your answer: \(if .verdict == "idk" then "I don'"'"'t know" else "free text: \(.answer)" end)\n  Correct answer: \(.correct)\n  Why: \(.explanation)\n  Evidence: \(.evidence)")
  ] | join("\n") end')"
exptext="$(printf '%s' "$batch" | jq -r '
  [ .[] | select(.verdict == "idk" or .verdict == "other")
    | "\(.label) [\(.topic)]: \(.question)\n  Developer answer: \(if .verdict == "idk" then "I don'"'"'t know (explain the whole topic)" else "free text: \(.answer)" end)\n  Correct answer: \(.correct)\n  Why: \(.explanation)\n  Evidence: \(.evidence)" ]
  | if length == 0 then "none" else join("\n\n") end')"
rules="Never give the correct answer of a wrong question or of a question without an answer. The developer gets a new question on that topic, and its answer is explained after the pass."

updated="$(jq -c --argjson g "$graded" --argjson b "$batch" '
  .results += $g
  | .wrong_log = ((.wrong_log // []) + [ $b[] | select(.verdict != "ok" and .verdict != "idk" and .verdict != "other")
      | {label, question, answer, verdict, correct, explanation, evidence} ])' "$round")" \
  || say "pr-quiz ERROR: cannot update ${round}."
total="$(jq '.questions | length' "$keyfile")"
answered="$(printf '%s' "$updated" | jq --slurpfile key "$keyfile" '[.results | keys[] as $t | select($key[0].questions | any(.question == $t))] | length')"

if [ "$answered" -lt "$total" ]; then
  printf '%s' "$updated" | prq_write_json "$round" || say "pr-quiz ERROR: cannot update ${round}."
  tell "$devtext" "pr-quiz: round ${n} progress: ${answered} of ${total} questions answered. The developer already sees the result of this call. Do these steps now, in this order:
1. For each question under \"Explain now\", explain the topic from the code: the correct answer, why it is correct, and the code at the evidence path:line.
2. ${rules}
3. Ask the remaining questions of round ${n}.

Explain now:
${exptext}"
fi

failed="$(printf '%s' "$updated" | jq -c --slurpfile key "$keyfile" '[.results as $res | $key[0].questions[] | select($res[.question].verdict != "ok") | .topic] | unique')"
nfail="$(printf '%s' "$failed" | jq 'length')"
correct=$((total - nfail))

if [ "$nfail" -eq 0 ]; then
  base="$(jq -r .base "$round")"; head="$(jq -r .head "$round")"
  # The scope base recorded at start: a fetch during the quiz cannot widen the pass.
  scope="$(jq -r '.mb // .base_ref' "$round")"
  pid="$(prq_patch_id "$scope" "$head")" || say "pr-quiz ERROR: all answers are correct, but the pass was not written: no merge base of ${scope:0:12} and ${head:0:7}."
  printf '%s' "$updated" | jq --arg pid "$pid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repo, branch, base, head, patch_id:$pid, rounds:.round, at:$at,
      history:(.history + [{round:.round, total:(.results | length), correct:(.results | length), failed:[]}])}' \
    | prq_write_json "${PRQ_STATE}/pass.json" || say "pr-quiz ERROR: all answers are correct, but ${PRQ_STATE}/pass.json was not written."
  recap="$(printf '%s' "$updated" | jq -r '
    (.wrong_log // []) | if length == 0 then "" else
    "Recap of the questions you answered wrong:\n" + (map("\(.label) \"\(.question)\"\n  Your answer: \(if .verdict == "wrong" then .answer else "none" end)\n  Correct answer: \(.correct)\n  Why: \(.explanation)\n  Evidence: \(.evidence)") | join("\n\n")) end')"
  rm -f "$round" "${PRQ_STATE}"/key-*.json
  scores="$(jq -r '[.history[] | "round \(.round) \(.correct)/\(.total)"] | join(", ")' "${PRQ_STATE}/pass.json")"
  [ -n "$recap" ] && recap_ctx="Then explain each question in the recap below from the code at its evidence path:line." || recap_ctx=""
  dev="🎆 PR quiz passed! ${PRQ_BRANCH} at ${head:0:7}. Scores: ${scores}. The PR gate is open. 🎉"
  [ -n "$recap" ] && dev="${dev}

${recap}"
  tell "$dev" "pr-quiz: PASS. Round ${n}: ${correct} of ${total} correct, so every topic is now correct. Scores: ${scores}. The PR gate is open for branch ${PRQ_BRANCH} at ${head:0:7} (base ${base}). Tell the developer the result and the scores. ${recap_ctx} If a PR command was blocked before the quiz, run it again now.${recap:+

${recap}}"
fi

printf '%s' "$updated" | jq --argjson failed "$failed" --argjson total "$total" --argjson correct "$correct" \
  '.status = "done" | .failed = $failed | .history += [{round:.round, total:$total, correct:$correct, failed:$failed}]' \
  | prq_write_json "$round" || say "pr-quiz ERROR: cannot update ${round}."
labels="$(printf '%s' "$updated" | jq -r --slurpfile key "$keyfile" --arg lp "$lp" '[.results as $res | $key[0].questions | to_entries[] | select($res[.value.question].verdict != "ok") | "\($lp)Q\(.key + 1)"] | join(", ")')"
tell "${devtext}

Round ${n} result: ${correct} of ${total} correct. Failed: ${labels}. Next: round $((n + 1)) with ${nfail} new question(s), one for each failed question." \
"pr-quiz: round ${n} result: ${correct} of ${total} correct. Failed topics: $(printf '%s' "$failed" | jq -r 'join(", ")').
The developer already sees this result. Do these steps now, in this order:
1. For each question under \"Explain now\", explain the topic from the code: the correct answer, why it is correct, and the code at the evidence path:line.
2. ${rules}
3. Ask the developer with AskUserQuestion (a normal question with the header \"Next round\", not a Q header) whether they are ready for round $((n + 1)) with ${nfail} new question(s).
4. On yes: run ${helper} start. Write one new question for each failed topic, with new wording and a new angle. Register it with ${helper} key, then ask it with the header \"R$((n + 1)) Q1/${nfail}\" and so on.

Explain now:
${exptext}"
