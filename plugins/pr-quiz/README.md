# pr-quiz

Claude Code writes code fast. Before it opens a pull request for you, you should know what is in it. pr-quiz blocks Claude from opening a pull request until you pass a multiple-choice quiz about the branch. With the merge check on, a PR that someone opened outside Claude cannot merge until the quiz passes either, on GitHub and on Azure DevOps.

## How it works

1. You ask Claude to open a PR. A hook blocks `gh pr create` (and the other PR commands below) because no quiz pass exists for this commit.
2. Claude reads the branch diff and writes 10 questions. Each question has 3 answers and the option **"I don't know, explain this to me"**. Claude registers an answer key before it asks anything. The key is frozen at the first question.
3. You answer in the normal Claude Code question dialog, 4 questions at a time.
4. A hook grades your real answers against the frozen key. Claude never grades.
5. After each set of questions, the hook shows you how many answers were wrong and which questions. It does not show the correct answer of a wrong question. It explains every "I don't know" answer at once, and Claude walks you through that code before the next questions.
6. At the end of the round you see your score. Claude asks whether you are ready for the next round. The next round has one new question for each question you failed, so 2 failed questions give 2 new questions.
7. You pass. Claude Code shows you a celebration line with your scores per round, and a recap that gives the correct answer for every question you answered wrong. The pass is recorded for the branch, base and repo. Claude runs the PR command again and the gate lets it through.

After a pass:

- A new commit needs a short quiz of 3 questions about the new changes only.
- A rebase that does not change the diff keeps the pass. The check uses `git patch-id --verbatim`, so even an indentation change that changes behavior voids the pass.
- Rewritten history (an amended or squashed commit that you passed on) needs a full quiz again.
- To take the full quiz again, ask Claude to restart it. It runs `pr-quiz reset --all`, which drops the pass.

Why 3 answers and not 4: the Claude Code question dialog takes at most 4 options, and it always adds "Other" for a typed answer. A typed answer counts as wrong, and it is explained like "I don't know".

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

Requirements: bash 3.2 or later, git 2.39 or later, and jq. The merge check also needs gh (GitHub) or curl plus the Azure CLI or a PAT (Azure DevOps). Tested on macOS (bash 3.2) and Linux (bash 5). Windows is not tested.

You can also start a quiz yourself at any time: `/pr-quiz:quiz`.

## Merge check

The PR gate stops Claude. The merge check also stops a PR that someone opened in the browser or in their own terminal: the platform blocks the merge until pr-quiz posts the status `pr-quiz/merge-check`.

After a pass, pr-quiz posts a success status for HEAD. It posts again after a push or a PR command through Claude, and when you run `/pr-quiz:quiz` while the pass is still valid. A new commit gets no status until its short quiz passes.

| Platform | What pr-quiz posts | Credentials |
|---|---|---|
| GitHub (and GitHub Enterprise) | A commit status on HEAD, context `pr-quiz/merge-check` | Your gh login for the host, with push access |
| Azure DevOps | A PR status on each active PR from the branch to the quiz base, on the PR iteration whose commit is HEAD. Genre `pr-quiz`, name `merge-check`. | `az login` (Entra token), or `AZURE_DEVOPS_EXT_PAT` with the Code (status) scope. The token goes to curl on stdin, never on the command line. |

Before it posts, pr-quiz reads the base branch on the remote (`git ls-remote`) and checks that the pass covers HEAD against it. A pass that was scoped against a stale or moved local base gets no status.

### Turn it on or off

Turn it on in this order: first the switch, then the required check. Turn it off in reverse order. Otherwise merges wait for a status that never comes.

| Where | On | Off |
|---|---|---|
| The team, in the repo | Commit `.claude/pr-quiz.json` with `{"merge_check": true}` | Set `false`, or delete the file |
| One developer | `"env": {"PR_QUIZ_MERGE_CHECK": "on"}` in `.claude/settings.local.json` | The same with `"off"`. The env beats the repo file. pr-quiz tells you when your `off` stops a status that the repo turns on. |
| GitHub | Settings > Rules > Rulesets > a branch ruleset on the default branch > Require status checks to pass > add `pr-quiz/merge-check` > Enforcement status Active | Enforcement status Disabled, or remove the check |
| Azure DevOps | Repos > Branches > the default branch > Branch policies > Status checks > + > status `pr-quiz/merge-check` > Policy requirement Required > Reset status whenever there are new changes > Apply by default > display name `pr-quiz: run /pr-quiz:quiz in Claude Code` | Policy requirement Optional, or delete the policy |

The default is off: without the repo file or the env, pr-quiz posts nothing and makes no network call.

## What the gate covers

| Blocked until you pass | Notes |
|---|---|
| `gh pr create`, `gh pr new` | Also after `cd` (quoted paths with spaces too), `pushd`, subshells, `&&`, `;`, line continuations, redirections, env prefixes, `env`, `bash -c "..."`, `eval "..."`, `command gh`, gh flags before the subcommand and gh aliases. With no `--base`, the base is the branch's `gh-merge-base` config, else the origin default branch. `--head`, `--base` and `--repo` must match the quizzed branch, base and origin. |
| `gh pr ready` | Only without a PR number, so that it acts on the current branch. |
| `glab mr create`, `hub pull-request`, `tea pr create` | Head and base are checked. |
| `az repos pr create` | Source and target are checked. `--repository`, `--project` and `--org` must name the origin repo (case-insensitive; a GUID is refused). |
| MCP tools named `*create_pull_request` or `*create_merge_request` | Head, base, owner and repo are checked. |
| The Azure DevOps MCP tool `repo_pull_request_write` with `action: "create"` | Source and target are checked. `repositoryId` and `project` must name the origin repo. |

Always blocked, because pr-quiz cannot check head and base: `gh api`, `glab api` and `hub api` POST calls to a pulls or merge requests endpoint, `curl` and `wget` POST calls to such an endpoint (with or without a scheme, and through `--request-target`), `az devops invoke` and `az rest` calls that create a PR, and GraphQL `createPullRequest` mutations. Use `gh pr create`.

Always blocked, because they would void the merge check:

- Status writes: `gh api` or `hub api` POST to a statuses endpoint, curl and wget POST or PATCH to a statuses URL, `az devops invoke` with a status resource, `az rest` POST or PATCH to a statuses URL, and MCP tools named `*create_commit_status`. Only the pr-quiz helper posts the status.
- Merges that skip the rules: `gh pr merge --admin`, `az repos pr create` or `update` with `--bypass-policy true`, and `repo_pull_request_write` with `bypassPolicy: true`.

The plugin also blocks Claude from writing the quiz state (`<git dir>/pr-quiz/`), from editing the installed plugin, and from running `claude plugin disable` or `uninstall` for it.

## Limits

pr-quiz is a guardrail against a PR that nobody understood. It is not a security boundary.

- Claude writes the answer key and can read it. Claude also chooses the questions, so a weak quiz is possible. Every question must cite a file from the diff, and you see every question.
- The gate parses shell commands with heuristics. It cannot see a PR command that is defined somewhere else and then run by name. That includes a script file, a shell function or alias, a git alias, a Makefile or package.json script, and code passed to another interpreter (`python -c`, `node -e`).
- When the gate cannot resolve a command, it blocks it. Examples are a program name in a variable or `$(...)`, and a `cd` to a variable, `cd -` or `popd` before a PR command. The gate also reads heredoc bodies as commands, because `bash <<EOF` runs its body. So `cat > notes.md <<EOF` with a PR command inside is blocked too.
- The gate reads a command twice. The first pass splits at every `;`, `&`, `|`, `(` and `)`, also inside quotes, so a quoted text such as `-m "fix; gh pr create later"` can be blocked. The second pass respects quotes, so a quoted title cannot hide the flags after it. The second pass skips commands over 32 KB, because it takes about 1 second per 20 KB on bash 3.2.
- Behind a wrapper such as `env`, `nohup`, `sudo`, `timeout` or `xargs`, the gate checks every word for a PR program, not only the wrapped program. So `env printf "%s\n" gh pr create` is blocked, although it only prints text. Quote the text to avoid it.
- Another hook can answer a question for you (an `AskUserQuestion` hook with `updatedInput`). pr-quiz cannot tell that answer from yours. It refuses questions that arrive with answers already filled in.
- Without the merge check, you can always open and merge a PR yourself in your terminal or in the browser. The gate stops Claude, not you.
- With the merge check, anyone with push access (GitHub) or Contribute access (Azure DevOps) can still post the status by hand. A ruleset bypass actor, or an Azure DevOps user with the bypass permission, can still merge. The merge check catches habit, not intent.
- On GitHub the status belongs to the commit, so a second PR from the same branch to another base sees it too.
- The PR gate scopes the quiz with your local `origin/<base>` ref. The merge check uses the remote base, so a quiz on a stale local base gets no status.
- An Azure DevOps Server ssh remote is not supported for the merge check. Use an https remote.
- MCP tools that write a status are recognized by the name `create_commit_status` only.
- Headless runs (`claude -p` without a permission prompt tool) and subagents cannot ask questions. With pr-quiz on, they cannot open PRs.
- `git push` to a branch that already has a PR is not gated. With the merge check on, the new commit gets no status until its short quiz passes.

## Files

| Path | Role |
|---|---|
| `hooks/pr-gate.sh` | PreToolUse on Bash and MCP PR tools: the gate |
| `hooks/quiz-pre.sh` | PreToolUse on AskUserQuestion: checks each quiz call against the key and freezes it |
| `hooks/quiz-post.sh` | PostToolUse on AskUserQuestion: grades, gives feedback after each call, writes the pass, gives the recap |
| `hooks/merge-check.sh` | PostToolUse on Bash and MCP PR tools: posts the merge check status after a push or PR command |
| `hooks/merge-check-lib.sh` | The switch, the remote base check and the GitHub and Azure DevOps posters |
| `hooks/state-guard.sh` | PreToolUse on edits and Bash: protects the state and the plugin |
| `skills/quiz/SKILL.md` | The quiz procedure Claude follows |
| `skills/quiz/scripts/pr-quiz` | Helper: `start`, `diff`, `key`, `status`, `reset [--all]`, `publish` |
| `evals/` | `claude plugin eval` cases |

## Development

```
bash tests/run.sh        # hook matrices: gate, quiz, guard, merge (stub gh, curl and az)
bash tests/mutation.sh   # each mutant disables one rule; the matrix must fail
```

`claude plugin eval plugins/pr-quiz --scaffold --allow-tools Bash --trust-plugin` runs the eval cases. An eval run cannot answer questions, so the grading proof is the hook matrix.
