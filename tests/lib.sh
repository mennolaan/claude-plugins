#!/usr/bin/env bash
# Test helpers: isolated git and gh config, fixture repos, hook runners and
# assertions. Sourced by tests/*.sh. PLUGIN points at the plugin under test.
# shellcheck disable=SC2034  # sourced: the test files read these variables

PLUGIN="${PRQ_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/pr-quiz" && pwd)}"
IDK="I don't know, explain this to me"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/prq-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMPROOT}/gitconfig" GH_CONFIG_DIR="${TMPROOT}/gh"
unset GH_REPO
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main
git config --global advice.detachedHead false
mkdir -p "$GH_CONFIG_DIR"

PASSED=0; FAILED=0
ok() { PASSED=$((PASSED + 1)); [ -n "${QUIET:-}" ] || printf 'ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# mk_repo: base commit on main (app.py, README.md, origin/main and origin/HEAD set),
# then branch feat with one commit that changes app.py. Prints the repo path.
mk_repo() {
  local d
  d="$(mktemp -d "${TMPROOT}/repo.XXXXXX")"
  (
    cd "$d" && git init -q && git remote add origin https://github.com/Acme/Demo.git \
    && printf 'def f(x):\n    if x:\n        a()\n    b()\n    return 1\n' > app.py && printf 'demo\n' > README.md \
    && git add . && git commit -qm base \
    && git update-ref refs/remotes/origin/main HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main \
    && git checkout -qb feat && sed -i.bak 's/return 1/return 2/' app.py && rm -f app.py.bak && git commit -qam "feat: return 2"
  ) || { echo "FATAL: cannot build fixture repo" >&2; exit 1; }
  printf '%s' "$d"
}

commit_in() { (cd "$1" && printf '%s\n' "$2" >> app.py && git commit -qam "change: $2"); }

# hook <script> <json>: sets OUT, ERR and RC.
hook() {
  OUT="$(printf '%s' "$2" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "${PLUGIN}/hooks/$1" 2>"${TMPROOT}/stderr")"; RC=$?
  ERR="$(cat "${TMPROOT}/stderr")"
}
bash_in() { jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'; }
tool_in() { jq -cn --arg t "$1" --argjson i "$2" --arg d "$3" '{tool_name:$t,tool_input:$i,cwd:$d}'; }

reason() { printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
sysmsg() { printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null; }

expect_deny() { # <name> <regex in the reason>
  local r; r="$(reason)"
  if [ "$RC" = 0 ] && [ -n "$r" ] && printf '%s' "$r" | grep -Eq -- "$2"; then ok "$1"
  elif [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -Eq -- "$2"; then ok "$1"
  else bad "$1" "want deny matching /$2/, got rc=$RC out=${OUT:-<none>} err=${ERR:-<none>}"; fi
}
expect_allow() { # <name>
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1" "want allow (no output), got rc=$RC out=$OUT err=$ERR"; fi
}
expect_ctx() { # <name> <regex in the additional context>
  local c; c="$(context)"
  if [ "$RC" = 0 ] && printf '%s' "$c" | grep -Eq -- "$2"; then ok "$1"; else bad "$1" "want context matching /$2/, got rc=$RC out=$OUT err=$ERR"; fi
}
expect_sysmsg() { # <name> <regex in the message shown to the developer>
  local m; m="$(sysmsg)"
  if [ "$RC" = 0 ] && printf '%s' "$m" | grep -Eq -- "$2"; then ok "$1"; else bad "$1" "want systemMessage matching /$2/, got rc=$RC out=$OUT"; fi
}
expect_true() { if (set +o pipefail; eval "$2"); then ok "$1"; else bad "$1" "condition false: $2"; fi; }

# Quiz helpers --------------------------------------------------------------

helper() { (cd "$REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "${PLUGIN}/skills/quiz/scripts/pr-quiz" "$@" 2>&1); }
state_dir() { (cd "$REPO" && printf '%s/pr-quiz/%s' "$(git rev-parse --absolute-git-dir)" "$(printf '%s' "$(git symbolic-ref -q --short HEAD)" | git hash-object --stdin | cut -c1-16)"); }
has_pass() { [ -f "$(state_dir)/pass.json" ]; }

# make_key <count> [prefix] [topics json]: a valid key with rotating correct positions.
make_key() {
  jq -cn --argjson n "$1" --arg p "${2:-Question}" --argjson topics "${3:-null}" '
    {questions: [range(0; $n) as $i
      | ["Alpha \($p) \($i + 1)", "Beta \($p) \($i + 1)", "Gamma \($p) \($i + 1)"] as $o
      | {topic: (if $topics then $topics[$i] else "t\($i + 1)" end),
         question: "\($p) \($i + 1): what does the change do to f?",
         options: $o, correct: $o[$i % 3], evidence: "app.py:5",
         explanation: "Line 5 returns 2 now. Answer \($i + 1)."}]}'
}

# ask_json <key file> <from> <to> <header prefix>: AskUserQuestion input for questions from..to (1-based).
ask_json() {
  jq -c --argjson a "$2" --argjson b "$3" --arg h "$4" --arg idk "$IDK" '
    (.questions | length) as $tot
    | {questions: [.questions | to_entries[] | select(.key + 1 >= $a and .key + 1 <= $b)
        | {question: .value.question, header: "\($h)Q\(.key + 1)/\($tot)",
        options: ([.value.options[] | {label: ., description: ""}] + [{label: $idk, description: ""}]),
        multiSelect: false}]}' "$1"
}

# post_json <ask json> <answers json> [extra tool_response json]
post_json() {
  local x="${3:-}"; [ -n "$x" ] || x='{}'
  jq -cn --argjson i "$1" --argjson a "$2" --argjson x "$x" --arg d "$REPO" \
    '{tool_name:"AskUserQuestion", tool_input:$i, tool_response:($i + {answers:$a} + $x), cwd:$d}'
}
pre_json() { jq -cn --argjson i "$1" --arg d "$REPO" '{tool_name:"AskUserQuestion", tool_input:$i, cwd:$d}'; }

# correct_answers <key file> <from> <to>: answers object with every correct label.
correct_answers() {
  jq -c --argjson a "$2" --argjson b "$3" '[.questions | to_entries[] | select(.key + 1 >= $a and .key + 1 <= $b) | {key: .value.question, value: .value.correct}] | from_entries' "$1"
}

# ask_and_answer <key file> <from> <to> <answers json> [extra] [header prefix]: pre + post for one call.
ask_and_answer() {
  local ask; ask="$(ask_json "$1" "$2" "$3" "${6:-}")"
  hook quiz-pre.sh "$(pre_json "$ask")"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || { bad "pre-check for questions $2-$3" "unexpected deny: $OUT $ERR"; return 1; }
  hook quiz-post.sh "$(post_json "$ask" "$4" "${5:-}")"
}

# pass_quiz: start, register a 10-question key, answer all correctly in 4+4+2.
pass_quiz() {
  local k="${TMPROOT}/key.$$.$RANDOM.json"
  helper start >/dev/null
  make_key 10 "${1:-Question}" > "$k"
  helper key < "$k" >/dev/null || { bad "pass_quiz key" "$(helper key < "$k")"; return 1; }
  ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
  ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
  ask_and_answer "$k" 9 10 "$(correct_answers "$k" 9 10)"
}

finish() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSED" "$FAILED"
  [ "$FAILED" = 0 ]
}
