---
name: quiz
description: Quiz the developer with multiple-choice questions about the current branch's changes before a pull request is opened. Use when the pr-quiz gate blocks a PR command, or when the developer asks for the PR quiz.
---

# PR quiz

The developer must show that they understand the change before Claude opens a pull request. You write the questions from the diff. Hooks check every question against the key that you register, and they grade the developer's real answers. You never grade, and you never write quiz state yourself.

The helper is `"${CLAUDE_SKILL_DIR}/scripts/pr-quiz"`. Run it from inside the repo checkout. In the steps below, `pr-quiz` means that path.

## Procedure

1. Run `pr-quiz start` (add `--base <branch>` when the PR targets a branch that is not the default). It prints the mode (full or delta), the number of questions, the commits, the diff stat and the files that a question may cite. If it says that a pass is valid, stop: run the blocked PR command again.
2. Run `pr-quiz diff` and read the whole diff. Read the surrounding code where a hunk is not clear alone.
3. Write the answer key (format below). Full mode: 10 questions. Delta mode: 3 questions about the new commits only. Retry round: one question for each failed topic.
4. Register the key: `pr-quiz key <<'EOF'` followed by the JSON and `EOF`. If it prints FAIL, fix every listed item and register again. It must print `registered round N`.
5. Ask the questions with AskUserQuestion. At most 4 questions per call, so 10 questions take 3 calls (4, 4, 2). For every question:
   - `question`: the exact question text from the key.
   - `header`: `Q<i>/<total>` in round 1, for example `Q3/10`. In retry round N: `R<N> Q<i>/<total>`, for example `R2 Q1/3`.
   - `options`: the 3 key options in key order, then the option `I don't know, explain this to me` as the last one. Every `description` is an empty string.
   - `multiSelect`: false.
6. After each call, the hook shows the developer the result of that call: how many answers were wrong and which questions, without the correct answer. It explains every "I don't know" or free-text answer at once. Before you ask the next call, do what the hook message says:
   - For each question under "Explain now", explain the topic from the code: the correct answer, why it is correct, and the code at the evidence path:line.
   - Never give the correct answer of a wrong question, or of a question without an answer. The developer gets a new question on that topic, and the answer comes in the recap after the pass.
7. When the round is complete with failed questions, do what the hook message says: explain the "Explain now" questions, then ask with AskUserQuestion (a normal question with the header `Next round`) whether the developer is ready for the next round. The next round has exactly one new question for each failed question. On yes, start the retry round at step 1.
8. When the hook reports PASS, tell the developer the scores. Then explain each question in the recap from the code at its evidence path:line. Then run the blocked PR command again.

## Writing good questions

- Every question tests understanding of this change, not trivia. The developer must be able to answer it from the diff and the PR purpose.
- Spread the 10 round 1 topics over these areas, one topic each: why the change exists; the behavior that changes; where in the code it lives; interfaces and contracts; configuration and data; failure modes and edge cases; security; how it was tested; rollout and rollback; what the change does not do. When an area does not apply, use a second topic from the area that matters most.
- A topic name is short and specific, for example `token-refresh-retry`. A retry question keeps the topic name of the failed question.
- Exactly 1 option is correct. The 2 wrong options are plausible: they use real names from the diff and describe something that the code could do but does not.
- Do not give the answer away. The question text, the option length and the option wording must not point at the correct option. Put the correct option at a different position in different questions.
- `evidence` is `path:line` (or `path:start-end`) of a file in the diff that proves the correct answer.
- `explanation` says in 2 to 4 sentences why the correct answer is correct and why the other options are wrong.
- A retry question is new: new wording and a new angle on the same topic. Never ask a question again.

## Key format

```json
{
  "questions": [
    {
      "topic": "token-refresh-retry",
      "question": "What does the client do when the token refresh call returns 401?",
      "options": [
        "It retries the refresh 3 times with backoff",
        "It clears the session and sends the user to sign in",
        "It keeps the old token until it expires"
      ],
      "correct": "It clears the session and sends the user to sign in",
      "evidence": "src/auth/client.ts:88-97",
      "explanation": "A 401 from the refresh endpoint means that the refresh token is revoked, so a retry cannot succeed. Line 91 calls clearSession() and redirects. Nothing in the diff retries, and the old token is dropped at once."
    }
  ]
}
```

## Rules

- Never answer a quiz question for the developer, and never put answers in the AskUserQuestion call.
- Never read, write or delete files under the git directory's `pr-quiz` folder. Use `pr-quiz status` and `pr-quiz reset`.
- `pr-quiz reset` drops the open round and keeps a pass. When the developer asks to restart the quiz, run `pr-quiz reset --all`: it drops the pass too, then `pr-quiz start` begins a full quiz.
- If the developer stops the quiz, the PR gate stays closed. Say so, and stop.
- If HEAD changes during the quiz, run `pr-quiz start` again. The open round is replaced.
