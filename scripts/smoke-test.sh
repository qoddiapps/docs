#!/usr/bin/env bash
# Regression check for the AppJet docs site.
#
# Guards the failure that took the site down (Cloudflare 520 / origin down):
#  - the container start command used `mintlify dev --host 0.0.0.0 --port 3000`,
#    but the Mintlify CLI has no --port flag and --host is a boolean, so the CLI
#    exited with "Unknown command: 0.0.0.0" and nothing listened on 0.0.0.0:3000.
#  - without --host the preview binds [::1] only, which the platform proxy
#    cannot reach, which is just as broken.
#
# Section 1 asserts the Dockerfile keeps a start command that actually works.
# Section 2 boots the real server and asserts it serves the documentation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAILURES=0
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
ok()   { echo "ok:   $*"; }

# ---------------------------------------------------------------- section 1
echo "== Dockerfile start-command guards =="

[[ -f Dockerfile ]] || fail "Dockerfile is missing"
[[ -f docs.json ]]  || fail "docs.json is missing"

CMD_LINE="$(grep -E '^[[:space:]]*CMD' Dockerfile || true)"
if [[ -z "$CMD_LINE" ]]; then
  fail "Dockerfile has no CMD (container would exit immediately -> 502/520)"
else
  ok "CMD present: $CMD_LINE"

  [[ "$CMD_LINE" == *mintlify* ]] || fail "CMD must invoke the mintlify CLI"
  [[ "$CMD_LINE" == *dev* ]]      || fail "CMD must run the 'dev' subcommand"

  if [[ "$CMD_LINE" == *--host* ]]; then
    ok "CMD passes --host (binds 0.0.0.0, reachable by the platform proxy)"
  else
    fail "CMD must pass --host: otherwise the preview binds [::1] and is unreachable"
  fi

  # --host is a boolean flag; a value after it is parsed as a command name.
  if [[ "$CMD_LINE" == *--host*0.0.0.0* || "$CMD_LINE" == *--host*localhost* ]]; then
    fail "CMD passes a value to --host, which the CLI reads as a command ('Unknown command')"
  fi
  if [[ "$CMD_LINE" == *--port* ]]; then
    fail "CMD passes --port, which this CLI does not support (it exits with usage error)"
  fi
fi

grep -qE '^[[:space:]]*EXPOSE[[:space:]]+3000' Dockerfile \
  || fail "Dockerfile must EXPOSE 3000 (matches the deployment port)"
grep -qE '^[[:space:]]*ENV[[:space:]]+PORT=3000' Dockerfile \
  || fail "Dockerfile must set ENV PORT=3000"

# A pinned CLI keeps an upstream `@latest` release from breaking the build again.
if grep -q '@mintlify/cli@latest' Dockerfile; then
  fail "Dockerfile installs @mintlify/cli@latest; pin a known-good version instead"
elif grep -qE '@mintlify/cli@[0-9]' Dockerfile; then
  ok "CLI version is pinned"
else
  fail "Dockerfile does not install a pinned @mintlify/cli"
fi

# ---------------------------------------------------------------- section 2
echo
echo "== HTTP smoke test (real server on port 3000) =="

LOG="$(mktemp -t docs-smoke.XXXXXX.log)"
setsid npx --yes @mintlify/cli dev --host --no-open >"$LOG" 2>&1 &
SRV_PID=$!
cleanup() {
  kill -TERM -- "-$SRV_PID" 2>/dev/null
  sleep 2
  kill -KILL -- "-$SRV_PID" 2>/dev/null
  rm -f "$LOG"
}
trap cleanup EXIT

# Mintlify always serves on 3000 (the CLI ignores PORT), so wait for that port.
ready=0
for _ in $(seq 1 60); do
  sleep 3
  if curl -s -o /dev/null --max-time 5 http://127.0.0.1:3000/ 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "--- server log ---"
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | grep -v '^[[:space:]]*$' | tail -20
    fail "the mintlify server exited before serving any request"
    break
  fi
done

if [[ "$ready" -eq 1 ]]; then
  ok "server accepted a connection on 127.0.0.1:3000"

  # Bound to all interfaces? Required for the platform proxy to reach it.
  if ss -ltn 2>/dev/null | grep -E ':3000[[:space:]]' | grep -qE '\*:3000|0\.0\.0\.0:3000'; then
    ok "port 3000 is bound on all interfaces"
  else
    fail "port 3000 is not bound on 0.0.0.0 (proxy traffic cannot reach it)"
  fi

  BODY="$(mktemp -t docs-body.XXXXXX)"
  for path in / /quickstart /essentials/deploy /essentials/troubleshoot; do
    code="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 40 "http://127.0.0.1:3000$path")"
    if [[ "$code" == "200" ]]; then
      ok "$path -> 200 ($(wc -c <"$BODY") bytes)"
    else
      fail "$path -> HTTP $code (expected 200)"
    fi
  done

  # The home page must render the docs shell, not an empty/error body.
  if curl -s --max-time 40 http://127.0.0.1:3000/ | grep -qi 'AppJet'; then
    ok "home page renders AppJet content"
  else
    fail "home page does not contain the expected 'AppJet' content"
  fi

  # A nested page must render its own title, proving routing works.
  if curl -s --max-time 40 http://127.0.0.1:3000/quickstart | grep -qi 'Quickstart'; then
    ok "nested page /quickstart renders its own content"
  else
    fail "nested page /quickstart did not render expected content"
  fi

  rm -f "$BODY"

  # The crash loop that preceded the outage must not be happening.
  if sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | grep -qE 'Unknown command|Cannot read properties of undefined'; then
    fail "server log contains a fatal CLI error (crash loop)"
  else
    ok "no fatal CLI errors in the server log"
  fi
fi

# -------------------------------------------------------------------- result
echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "RESULT: FAILED ($FAILURES assertion(s) failed) — the deployed docs site would not serve."
  exit 1
fi
echo "RESULT: PASSED — Dockerfile start command is valid and the server serves the docs on 0.0.0.0:3000."
exit 0
