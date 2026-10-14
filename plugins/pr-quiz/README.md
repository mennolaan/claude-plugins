# pr-quiz

Claude Code writes code fast. Before it opens a pull request for you, you should know what is in it. pr-quiz blocks Claude from opening a pull request until you pass a multiple-choice quiz about the branch.

## How it works

1. You ask Claude to open a PR. A hook blocks `gh pr create` (and the other PR commands below) because no quiz pass exists for this commit.
2. Claude reads the branch diff and writes 10 questions. Each question has 3 answers and the option **"I don't know, explain this to me"**. Claude registers an answer key before it asks anything. The key is frozen at the first question.
3. You answer in the normal Claude Code question dialog, 4 questions at a time.
4. A hook grades your real answers against the frozen key. Claude never grades.
5. After the 10 questions you get your score. Claude explains every wrong answer and every "I don't know", with the code location that proves the correct answer.
6. Claude asks whether to retry. A retry asks one new question for each failed topic. This repeats until every topic is correct.
7. The pass is recorded for the branch, base and repo. Claude runs the PR command again and the gate lets it through.

After a pass:

- A new commit needs a short quiz of 3 questions about the new changes only.
- A rebase that does not change the diff keeps the pass. The check uses `git patch-id --verbatim`, so even an indentation change that changes behavior voids the pass.
- Rewritten history (an amended or squashed commit that you passed on) needs a full quiz again.

## Install

```
/plugin marketplace add mennolaan/claude-plugins
/plugin install pr-quiz@mennolaan
```

To turn it on for everyone in a project, add this to the project's `.claude/settings.json`. Team members get it after they trust the folder.

```json
{
  "extraKnownMarketplaces": {
    "mennolaan": { "source": { "source": "github", "repo": "mennolaan/claude-plugins" } }
  },
  "enabledPlugins": { "pr-quiz@mennolaan": true }
}
```

Requirements: bash 3.2 or later, git 2.39 or later, and jq. Tested on macOS (bash 3.2) and Linux (bash 5). Windows is not tested.

You can also start a quiz yourself at any time: `/pr-quiz:quiz`.

## What the gate covers

| Blocked until you pass | Notes |
|---|---|
| `gh pr create`, `gh pr new` | Also after `cd`, `pushd`, `&&`, `;`, line continuations, env prefixes, `bash -c`, `command gh`, gh flags before the subcommand and gh aliases. `--head`, `--base` and `--repo` must match the quizzed branch, base and origin. |
| `gh pr ready` | Only without a PR number, so that it acts on the current branch. |
| `glab mr create`, `az repos pr create`, `hub pull-request`, `tea pr create` | Head and base are checked. |
| MCP tools named `*create_pull_request` or `*create_merge_request` | Head, base, owner and repo are checked. |

Always blocked, because pr-quiz cannot check head and base: `gh api`, `glab api` and `hub api` POST calls to a pulls or merge requests endpoint, `curl` POST calls to such an endpoint, and GraphQL `createPullRequest` mutations. Use `gh pr create`.

The plugin also blocks Claude from writing the quiz state (`<git dir>/pr-quiz/`), from editing the installed plugin, and from running `claude plugin disable` or `uninstall` for it.

## Limits

pr-quiz is a guardrail against a PR that nobody understood. It is not a security boundary.

- Claude writes the answer key and can read it. Claude also chooses the questions, so a weak quiz is possible. Every question must cite a file from the diff, and you see every question.
- The gate parses shell commands with heuristics. It cannot see a PR command that is defined somewhere else and then run by name. That includes a script file, a shell function or alias, a git alias, a Makefile or package.json script, and code passed to another interpreter (`python -c`, `node -e`).
- When the gate cannot resolve a command, it blocks it. Examples are a program name in a variable or `$(...)`, and a `cd` to a variable, `cd -` or `popd` before a PR command.
- Another hook can answer a question for you (an `AskUserQuestion` hook with `updatedInput`). pr-quiz cannot tell that answer from yours. It refuses questions that arrive with answers already filled in.
- You can always open a PR yourself in your terminal or in the browser. The gate stops Claude, not you.
- Headless runs (`claude -p` without a permission prompt tool) and subagents cannot ask questions. With pr-quiz on, they cannot open PRs.
- `git push` to a branch that already has a PR is not gated.

## Files

| Path | Role |
|---|---|
| `hooks/pr-gate.sh` | PreToolUse on Bash and MCP PR tools: the gate |
| `hooks/quiz-pre.sh` | PreToolUse on AskUserQuestion: checks each quiz call against the key and freezes it |
| `hooks/quiz-post.sh` | PostToolUse on AskUserQuestion: grades, reports, writes the pass |
| `hooks/state-guard.sh` | PreToolUse on edits and Bash: protects the state and the plugin |
| `skills/quiz/SKILL.md` | The quiz procedure Claude follows |
| `skills/quiz/scripts/pr-quiz` | Helper: `start`, `diff`, `key`, `status`, `reset` |
| `evals/` | `claude plugin eval` cases |

## Development

```
bash tests/run.sh        # hook matrices: gate, quiz, guard
bash tests/mutation.sh   # each mutant disables one rule; the matrix must fail
```

`claude plugin eval plugins/pr-quiz --scaffold --allow-tools Bash --trust-plugin` runs the eval cases. An eval run cannot answer questions, so the grading proof is the hook matrix.
