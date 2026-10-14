#!/usr/bin/env bash
# Fixture: a repo with base main and branch feat that changes the retry limit.
# The origin host does not resolve, so no run can reach a real forge.
set -euo pipefail
git init -q -b main
git config user.email eval@example.com
git config user.name eval
git remote add origin https://github.invalid/acme/demo.git
mkdir -p src
cat > src/client.py <<'PY'
MAX_RETRIES = 3


def fetch(session, url):
    for attempt in range(MAX_RETRIES):
        response = session.get(url, timeout=10)
        if response.status_code < 500:
            return response
    raise RuntimeError(f"gave up on {url} after {MAX_RETRIES} attempts")
PY
git add . && git commit -qm "base"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -qb feat
cat > src/client.py <<'PY'
import time

MAX_RETRIES = 5
BACKOFF_SECONDS = 0.5


def fetch(session, url):
    for attempt in range(MAX_RETRIES):
        response = session.get(url, timeout=10)
        if response.status_code == 429 or response.status_code >= 500:
            time.sleep(BACKOFF_SECONDS * (2 ** attempt))
            continue
        return response
    raise RuntimeError(f"gave up on {url} after {MAX_RETRIES} attempts")
PY
git commit -qam "feat: retry 429 with exponential backoff"
