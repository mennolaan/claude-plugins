#!/usr/bin/env python3
"""End-to-end run of pr-quiz with a real model (manual; uses your Claude login).

Builds the eval fixture repo, starts `claude -p` in stream-json mode with the
plugin loaded, and asks Claude to open a PR. The script answers every
AskUserQuestion through the control protocol: in round 1 it answers Q2 wrong
and Q5 with "I don't know", everything else correctly (it reads the frozen key);
it says yes to the retry; later rounds are answered correctly. The origin host
does not resolve, so the final gh pr create cannot reach GitHub.

Usage: python3 -I tests/e2e.py [--model sonnet] [--keep]
       python3 -I tests/e2e.py --check <kept work dir>   (re-check a kept run, no model call)
Exit 0 when every checkpoint below is seen in the transcript.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "plugins", "pr-quiz")
FIXTURE = os.path.join(PLUGIN, "evals", "gate-blocks-pr", "fixture.sh")
IDK = "I don't know, explain this to me"
QUIZ_HEADER = re.compile(r"^(?:R(\d+) )?Q(\d+)/(\d+)$")
model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else "sonnet"

CHECK_ONLY = "--check" in sys.argv
work = tempfile.mkdtemp(prefix="prq-e2e.") if not CHECK_ONLY else sys.argv[sys.argv.index("--check") + 1]
repo = os.path.join(work, "repo")
if not CHECK_ONLY:
    os.makedirs(repo)
    subprocess.run(["bash", FIXTURE], cwd=repo, check=True)
    log = open(os.path.join(work, "stream.jsonl"), "w")


def git(*args):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()


def key_for(round_no):
    gitdir = git("rev-parse", "--absolute-git-dir")
    branch = git("symbolic-ref", "--short", "HEAD")
    h = subprocess.run(["git", "hash-object", "--stdin"], input=branch, capture_output=True, text=True, cwd=repo).stdout.strip()[:16]
    with open(os.path.join(gitdir, "pr-quiz", h, f"key-{round_no}.json")) as f:
        return {q["question"]: q for q in json.load(f)["questions"]}


def answer(inp):
    answers = {}
    for q in inp["questions"]:
        m = QUIZ_HEADER.match(q.get("header", ""))
        labels = [o["label"] for o in q["options"]]
        if not m:
            pick = next((l for l in labels if re.search(r"retry|yes", l, re.I)), labels[0])
            answers[q["question"]] = pick
            continue
        round_no, idx = int(m.group(1) or 1), int(m.group(2))
        k = key_for(round_no)[q["question"]]
        if round_no == 1 and idx == 2:
            answers[q["question"]] = next(o for o in k["options"] if o != k["correct"])
        elif round_no == 1 and idx == 5:
            answers[q["question"]] = IDK
        else:
            answers[q["question"]] = k["correct"]
    return answers


cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--permission-prompt-tool", "stdio", "--plugin-dir", PLUGIN, "--model", model,
       "--setting-sources", "project", "--allowedTools", "Bash", "Read", "Grep", "Glob", "Skill"]
p = None if CHECK_ONLY else subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(work, "stderr.txt"), "w"),
                     text=True, cwd=repo)


def send(o):
    p.stdin.write(json.dumps(o) + "\n")
    p.stdin.flush()


def tool_results(path):
    for line in open(path):
        m = json.loads(line)
        if m.get("type") == "user":
            for c in m["message"].get("content", []) if isinstance(m["message"].get("content"), list) else []:
                if c.get("type") == "tool_result":
                    t = c.get("content")
                    yield c.get("tool_use_id"), "".join(x.get("text", "") for x in t) if isinstance(t, list) else str(t)


def evaluate(work):
    """Checkpoints from the transcript and the repo state. Hook messages are not in stream-json."""
    repo, stream = os.path.join(work, "repo"), os.path.join(work, "stream.jsonl")
    calls, order = {}, []
    for line in open(stream):
        m = json.loads(line)
        if m.get("type") == "assistant":
            for c in m["message"].get("content", []):
                if c.get("type") == "tool_use":
                    calls[c["id"]] = c; order.append(c["id"])
    results = dict(tool_results(stream))
    asks = [i for i in order if calls[i]["name"] == "AskUserQuestion"]
    quiz_asks = [i for i in asks if any(QUIZ_HEADER.match(q.get("header", "")) for q in calls[i]["input"]["questions"])]
    gitdir = subprocess.run(["git", "rev-parse", "--absolute-git-dir"], cwd=repo, capture_output=True, text=True).stdout.strip()
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    passes = [os.path.join(d, "pass.json") for d in [os.path.join(gitdir, "pr-quiz", x) for x in os.listdir(os.path.join(gitdir, "pr-quiz"))]] if os.path.isdir(os.path.join(gitdir, "pr-quiz")) else []
    pas = json.load(open(passes[0])) if passes and os.path.exists(passes[0]) else {}
    hist = pas.get("history", [])
    prs = [i for i in order if calls[i]["name"] == "Bash" and "gh pr create" in calls[i]["input"].get("command", "")]
    last_ask = order.index(quiz_asks[-1]) if quiz_asks else len(order)
    after = [i for i in prs if order.index(i) > last_ask]
    return {
        "skill invoked": any(calls[i]["name"] == "Skill" and "quiz" in json.dumps(calls[i]["input"]) for i in order),
        "round 1 key registered with 10 questions": any("registered round 1: 10 questions" in r for r in results.values()),
        "every quiz question offers I don't know": bool(quiz_asks) and all(IDK in [o["label"] for o in q["options"]] for i in quiz_asks for q in calls[i]["input"]["questions"]),
        "round 1 graded 8 of 10 (1 wrong, 1 IDK)": bool(hist) and hist[0].get("correct") == 8 and len(hist[0].get("failed", [])) == 2,
        "retry round registered for the 2 failed topics": any(re.search(r"registered round 2: 2 questions", r) for r in results.values()),
        "pass written for the current HEAD": pas.get("head") == head and pas.get("rounds", 0) >= 2,
        "gh pr create ran after the pass": bool(after),
        "the gate did not block it after the pass": bool(after) and all("pr-quiz:" not in results.get(i, "") for i in after),
    }


if "--check" in sys.argv:
    work = sys.argv[sys.argv.index("--check") + 1]
    checks = evaluate(work)
    for k, v in checks.items():
        print(f"  {'ok  ' if v else 'MISS'} {k}")
    sys.exit(0 if all(checks.values()) else 1)

send({"type": "user", "message": {"role": "user", "content": "The branch feat is ready. Open a draft pull request for it with gh pr create."}})
final, deadline = "", time.time() + 1500
for line in p.stdout:
    log.write(line); log.flush()
    if time.time() > deadline:
        print("TIMEOUT"); break
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("type") == "control_request" and m["request"].get("subtype") == "can_use_tool":
        r = m["request"]
        if r["tool_name"] == "AskUserQuestion":
            ans = answer(r["input"])
            print("answering:", json.dumps(ans)[:300])
            resp = {"behavior": "allow", "updatedInput": dict(r["input"], answers=ans)}
        elif r["tool_name"] in ("Write", "Edit") and str(r["input"].get("file_path", "")).startswith((work, tempfile.gettempdir(), "/tmp", "/private/tmp")):
            resp = {"behavior": "allow", "updatedInput": r["input"]}
        else:
            print("denied tool:", r["tool_name"])
            resp = {"behavior": "deny", "message": "e2e: tool not allowed in this run"}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": resp}})
    if m.get("type") == "result":
        final = m.get("result") or ""
        break
p.stdin.close()
try:
    p.wait(timeout=60)
except subprocess.TimeoutExpired:
    p.kill()
log.close()

print("final message:\n" + final[:2500])
checks = evaluate(work)
print("\ncheckpoints:")
for k, v in checks.items():
    print(f"  {'ok  ' if v else 'MISS'} {k}")
print("transcript:", os.path.join(work, "stream.jsonl"))
ok = all(checks.values())
if ok and "--keep" not in sys.argv:
    shutil.rmtree(work)
sys.exit(0 if ok else 1)
