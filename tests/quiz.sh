#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT, RC and ERR are read by the lib.sh assertions
# Quiz matrix: key validation, the pre-check of every quiz call, grading of
# every answer kind, retry rounds, the key freeze, HEAD moves and delta mode.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k="${TMPROOT}/k.json"; k2="${TMPROOT}/k2.json"

# start ---------------------------------------------------------------------
REPO="$(mk_repo)"
out="$(helper start)"
expect_true "start reports full mode and 10 questions" 'printf "%s" "$out" | grep -q "Mode: full" && printf "%s" "$out" | grep -q "required in round 1: 10"'
expect_true "start lists app.py as citable" 'printf "%s" "$out" | grep -q "^  app.py$"'

# key validation ------------------------------------------------------------
reject() { # <name> <jq edit on a valid 10-question key> <regex in the FAIL output>
  local o
  make_key 10 | jq -c "$2" > "$k"
  o="$(helper key < "$k")"
  if printf '%s' "$o" | grep -q '^FAIL' && printf '%s' "$o" | grep -Eq -- "$3"; then ok "key rejected: $1"; else bad "key rejected: $1" "got: $o"; fi
}
reject "9 questions" '.questions |= .[0:9]' 'needs 10 questions, got 9'
reject "duplicate topic" '.questions[1].topic = "t1"' 'its own topic'
reject "2 options" '.questions[0].options |= .[0:2]' 'exactly 3 answers'
reject "IDK as an option" '.questions[0].options[2] = "I don'"'"'t know, explain this to me" | .questions[0].correct = .questions[0].options[0]' 'may not be'
reject "correct not an option" '.questions[0].correct = "Delta"' 'correct must equal'
reject "evidence outside the diff" '.questions[0].evidence = "README.md:1"' 'evidence must be'
reject "missing explanation" '.questions[0].explanation = ""' 'explanation is missing'
reject "duplicate question" '.questions[1].question = .questions[0].question' 'unique'
reject "same correct position everywhere" '.questions |= map(.correct = .options[0])' 'Shuffle'
make_key 10 > "$k"
out="$(helper key < "$k")"
expect_true "valid key registers round 1" 'printf "%s" "$out" | grep -q "registered round 1: 10 questions"'
expect_true "a key can be replaced before the first question" 'helper key < "$k" | grep -q "registered round 1"'

# pre-check -----------------------------------------------------------------
ask="$(ask_json "$k" 1 4 "")"
hook quiz-pre.sh "$(jq -cn --arg d "$REPO" '{tool_name:"AskUserQuestion",tool_input:{questions:[{question:"Which color?",header:"Color",options:[{label:"Red",description:""},{label:"Blue",description:""}],multiSelect:false}]},cwd:$d}')"
expect_allow "a normal question is not touched"
hook quiz-pre.sh "$(pre_json "$(printf '%s' "$ask" | jq -c '.questions[0].question = "Not in the key?"')")"; expect_deny "question not in the key" 'not in the round key'
hook quiz-pre.sh "$(pre_json "$(printf '%s' "$ask" | jq -c '.questions[0].options |= .[0:3]')")"; expect_deny "IDK option missing" 'options must be the 3 key options'
hook quiz-pre.sh "$(pre_json "$(printf '%s' "$ask" | jq -c '.questions[0].options += [{label:"Extra",description:""}]')")"; expect_deny "extra option" 'options must be'
hook quiz-pre.sh "$(pre_json "$(printf '%s' "$ask" | jq -c '.questions[0].multiSelect = true')")"; expect_deny "multiSelect" 'multiSelect must be false'
hook quiz-pre.sh "$(pre_json "$(printf '%s' "$ask" | jq -c --arg q "$(jq -r '.questions[0].question' "$k")" '.answers = {($q): "Alpha"}')")"; expect_deny "prefilled answers" 'prefilled answers'
hook quiz-pre.sh "$(pre_json "$ask")"; expect_allow "matching quiz call is allowed"
expect_true "first quiz call freezes the key" 'helper key < "$k" | grep -q "key is frozen"'

# grading: progress, then one failure of each kind in its own round ---------
hook quiz-post.sh "$(post_json "$ask" "$(correct_answers "$k" 1 4)")"; expect_ctx "partial round reports progress only" 'progress: 4 of 10'
expect_sysmsg "progress shows the developer the result of the call" 'questions 1 to 4: 4 of 4 correct\.'
expect_true "an all-correct call lists nothing wrong" '! sysmsg | grep -q "Wrong:"'
hook quiz-pre.sh "$(pre_json "$ask")"; expect_deny "an answered question cannot be asked again" 'already answered'
ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
# question 9 wrong, question 10 correct
ans="$(correct_answers "$k" 9 10 | jq -c --arg q "$(jq -r '.questions[8].question' "$k")" --arg w "$(jq -r '.questions[8] | (.options - [.correct])[0]' "$k")" '.[$q] = $w')"
ask_and_answer "$k" 9 10 "$ans"
expect_ctx "a wrong answer fails its topic" 'round 1 result: 9 of 10 correct. Failed topics: t9'
expect_true "a failed round does not celebrate" '! sysmsg | grep -q "PR quiz passed"'
expect_sysmsg "the developer sees which question was wrong" 'Wrong: Q9 "Question 9'
expect_true "a wrong answer shows nobody the correct answer" '! printf "%s" "$OUT" | grep -q "Gamma Question 9"'
expect_sysmsg "the round summary names the failed questions" 'Round 1 result: 9 of 10 correct\. Failed: Q9\. Next: round 2 with 1 new question'
expect_ctx "Claude asks if the developer is ready for the next round" 'ready for round 2 with 1 new question'
expect_true "the wrong answer is kept for the recap" '[ "$(jq -r ".wrong_log[0].label" "$(state_dir)/round.json")" = Q9 ]'
expect_true "a failed round writes no pass" '! has_pass'

# fail_round <name> <question index> <answer jq value or null> [extra tool_response] [verdict regex]
fail_round() {
  local o
  REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
  ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
  ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
  o="$(correct_answers "$k" 9 10 | jq -c --arg q "$(jq -r ".questions[$(($2 - 1))].question" "$k")" --argjson v "$3" 'if $v == null then del(.[$q]) else .[$q] = $v end')"
  ask_and_answer "$k" 9 10 "$o" "${4:-}"
  expect_ctx "$1 fails its topic" "9 of 10 correct. Failed topics: t$2"
  [ -z "${5:-}" ] || expect_out "$1 is reported as such" "$5"
  expect_true "$1 writes no pass" '! has_pass'
}
fail_round "\"I don't know\"" 10 "\"$IDK\"" "" "I don't know \\(explain the whole topic\\)"
expect_sysmsg "an I don't know answer is explained to the developer at once" 'Explained: Q10 "Question 10'
expect_sysmsg "the explanation gives the correct answer" 'Correct answer: Alpha Question 10'
fail_round "an Other free-text answer" 10 '"something I typed"' "" 'free text: something I typed'
expect_sysmsg "a free-text answer is explained like I don't know" 'Explained: Q10 .*Your answer: free text: something I typed'
fail_round "a missing answer" 10 null "" 'No answer, so wrong: Q10\.'
fail_round "an empty answer" 9 '""' "" 'No answer, so wrong: Q9\.'
REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)" '{"afkTimeoutMs":60000}'
expect_sysmsg "a timeout is reported as such" 'Q5 \(the question timed out\)'
ask_and_answer "$k" 9 10 "$(correct_answers "$k" 9 10)"
expect_ctx "an idle timeout fails every question of that call" '6 of 10 correct. Failed topics: t5, t6, t7, t8'
REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
ask_and_answer "$k" 9 10 "$(correct_answers "$k" 9 10)" '{"followUp":true}'
expect_ctx "a follow-up instead of an answer fails" '8 of 10 correct. Failed topics: t10, t9'

# retry round ---------------------------------------------------------------
REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4 | jq -c --arg q "$(jq -r '.questions[1].question' "$k")" --arg i "$IDK" '.[$q] = $i')"
expect_ctx "an I don't know answer mid-round is progress, not a result" 'progress: 4 of 10'
expect_sysmsg "an I don't know answer mid-round is explained before the next call" 'Explained: Q2 "Question 2.*Correct answer: Beta Question 2'
expect_ctx "Claude explains the I don't know topic before the next call" 'Explain now:.*Q2 \[t2\]'
ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
ask_and_answer "$k" 9 10 "$(correct_answers "$k" 9 10 | jq -c --arg q "$(jq -r '.questions[9].question' "$k")" '.[$q] = "Beta Question 10"')"
expect_ctx "round 1 fails t2 and t10" 'Failed topics: t10, t2'
expect_sysmsg "the round summary counts both failed questions" 'Failed: Q2, Q10\. Next: round 2 with 2 new question'
out="$(helper start)"
expect_true "start announces the retry round" 'printf "%s" "$out" | grep -q "Retry needed: round 2.*t10, t2"'
make_key 2 Retry '["t2","t3"]' > "$k2"
expect_true "retry key with the wrong topics is rejected" 'helper key < "$k2" | grep -q "exactly the failed topics"'
jq -c --slurpfile old "$k" '.questions[0].question = $old[0].questions[1].question' <(make_key 2 Retry '["t2","t10"]') > "$k2"
expect_true "retry key that repeats an old question is rejected" 'helper key < "$k2" | grep -q "asked in an earlier round"'
make_key 2 Retry '["t2","t10"]' > "$k2"
expect_true "valid retry key registers round 2" 'helper key < "$k2" | grep -q "registered round 2: 2 questions"'
hook quiz-pre.sh "$(pre_json "$(ask_json "$k" 1 2 "R2 ")")"; expect_deny "round 1 questions are not in the round 2 key" 'not in the round key'
ask_and_answer "$k2" 1 2 "$(correct_answers "$k2" 1 2)" "" "R2 "
expect_ctx "an all-correct retry round passes" 'PASS. Round 2: 2 of 2 correct'
expect_ctx "the pass tells Claude the score history" 'Scores: round 1 8/10, round 2 2/2'
expect_sysmsg "the pass celebrates to the developer directly" 'PR quiz passed! feat at [0-9a-f]{7}\. Scores: round 1 8/10, round 2 2/2\. The PR gate is open'
expect_sysmsg "the pass gives the recap of a wrong answer" 'Recap of the questions you answered wrong:'
expect_sysmsg "the recap gives the correct answer of the wrong question" 'Q10 "Question 10.*Your answer: Beta Question 10.*Correct answer: Alpha Question 10'
expect_true "the recap leaves out the question that was already explained" '! sysmsg | sed -n "/^Recap of the questions/,\$p" | grep -q "^Q2 "'
expect_ctx "Claude walks through the recap" 'explain each question in the recap'
expect_true "the pass is written" has_pass
expect_true "the pass records 2 rounds" '[ "$(jq -r .rounds "$(state_dir)/pass.json")" = 2 ]'
expect_true "start after a pass needs no quiz" 'helper start | grep -q "No quiz is needed"'
expect_true "reset keeps the pass" 'helper reset | grep -q "A pass, if any, stays" && has_pass'
expect_true "reset --all drops the pass" 'helper reset --all | grep -q "the pass for branch feat are dropped" && ! has_pass'
expect_true "start after reset --all is a full quiz" 'helper start | grep -q "required in round 1: 10"'

# key freeze and HEAD moves -------------------------------------------------
REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
jq '.questions[4].correct = .questions[4].options[0]' "$(state_dir)/key-1.json" > "${TMPROOT}/tampered" && cat "${TMPROOT}/tampered" > "$(state_dir)/key-1.json"
hook quiz-pre.sh "$(pre_json "$(ask_json "$k" 5 8 "")")"; expect_deny "a key edited after the freeze is refused" 'changed after the first question'
hook quiz-post.sh "$(post_json "$(ask_json "$k" 5 8 "")" "$(correct_answers "$k" 5 8)")"; expect_ctx "the grader refuses an edited key" 'no answer was graded'
REPO="$(mk_repo)"; helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
commit_in "$REPO" '# moved'
hook quiz-pre.sh "$(pre_json "$(ask_json "$k" 1 4 "")")"; expect_deny "HEAD moved during the quiz" 'HEAD moved'
REPO="$(mk_repo)"
hook quiz-pre.sh "$(pre_json "$(ask_json "$k" 1 4 "")")"; expect_deny "no open round" 'no quiz round is open'

# delta mode ----------------------------------------------------------------
REPO="$(mk_repo)"; pass_quiz
commit_in "$REPO" '# delta change'
out="$(helper start)"
expect_true "start after a new commit is a delta of 3" 'printf "%s" "$out" | grep -q "Mode: delta since" && printf "%s" "$out" | grep -q "required in round 1: 3"'
make_key 3 Delta > "$k"
expect_true "delta key registers 3 questions" 'helper key < "$k" | grep -q "registered round 1: 3 questions"'
ask_and_answer "$k" 1 3 "$(correct_answers "$k" 1 3)"
expect_ctx "an all-correct delta round passes" 'PASS'
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_allow "the delta pass opens the gate"

# A delta that only reverts a file still has files to cite.
REPO="$(mk_repo)"
(cd "$REPO" && printf 'more\n' >> README.md && git commit -qam "docs: more")
pass_quiz
(cd "$REPO" && git checkout -q main -- app.py && git commit -qm "revert app.py")
out="$(helper start)"
expect_true "revert-only delta lists the reverted file" 'printf "%s" "$out" | grep -q "^  app.py$"'
make_key 3 Revert > "$k"
expect_true "revert-only delta key registers" 'helper key < "$k" | grep -q "registered round 1: 3 questions"'

finish
