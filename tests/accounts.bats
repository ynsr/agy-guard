#!/usr/bin/env bats
# bats suite for `agy-guard accounts` — hermetic: stub CLI, fake proxy,
# throwaway $HOME, isolated keyring (dbus-run-session + temp keyring dir).
# Nothing here touches the real Secret Service or the live login.
#
# Requires: dbus-run-session, gnome-keyring-daemon, /usr/bin/python3
# with secretstorage. Individual keyring tests skip when tooling is absent.

setup_file() {
  SRC_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SRC_DIR
  export GUARD="$SRC_DIR/agy-guard"
  export HELPER="$SRC_DIR/agy-accounts"
  PROXY_PORT=$((20000 + RANDOM % 20000))
  export PROXY_PORT
  python3 "$SRC_DIR/tests/fake-proxy.py" "$PROXY_PORT" >"$BATS_FILE_TMPDIR/proxy.log" 2>&1 &
  echo $! >"$BATS_FILE_TMPDIR/proxy.pid"
  for _ in $(seq 1 50); do
    grep -q ready "$BATS_FILE_TMPDIR/proxy.log" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "fake proxy did not start" >&2
  return 1
}

teardown_file() {
  kill "$(cat "$BATS_FILE_TMPDIR/proxy.pid")" 2>/dev/null || true
}

setup() {
  TMP_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TMP_HOME/.local/bin" "$TMP_HOME/gemini" "$TMP_HOME/state"
  chmod 700 "$TMP_HOME/state"
  export HOME="$TMP_HOME"
  export PATH="$HOME/.local/bin:/usr/bin:/bin:$PATH"
  export AGY_GUARD_STATE_DIR="$TMP_HOME/state"
  export AGY_GUARD_GEMINI_DIR="$TMP_HOME/gemini"

  STUB="$BATS_TEST_TMPDIR/stub-cli-$$"
  cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*"
case "${STUB_MODE:-ok}" in
  quota) echo "ERROR: RESOURCE_EXHAUSTED quota exceeded for model" >&2; exit 1 ;;
  disabled) echo "account disabled for Terms of Service violation" >&2; exit 1 ;;
  auth) echo "UNAUTHENTICATED please reauthenticate" >&2; exit 1 ;;
  fail) echo "bogus failure" >&2; exit 7 ;;
esac
exit 0
EOF
  chmod +x "$STUB"
  export ANTIGRAVITY_CLI_BIN="$STUB"
  export ANTIGRAVITY_PROXY="http://127.0.0.1:$PROXY_PORT"
  export AGY_GUARD_PROBE_URL="http://probe.invalid/generate_204"
  export AGY_GUARD_PGREP_PATTERN="$BATS_TEST_TMPDIR/.*(antigravity-cli/agy|local/bin/agy)( |$)"
}

# --- isolated-keyring fixtures -------------------------------------------
# Each keyring test starts its own session bus holding a daemon unlocked
# with a throwaway password; teardown kills the whole session.
keyring_setup() {
  if ! command -v dbus-run-session >/dev/null 2>&1; then
    skip "no dbus-run-session"
  fi
  if ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
    skip "no gnome-keyring-daemon"
  fi
  KEYRING_PW="testpw-$$-$RANDOM"
  export KEYRING_PW
  BUS_ENV="$BATS_TEST_TMPDIR/bus-$$.env"
  export BUS_ENV
  KR_RUNTIME="$BATS_TEST_TMPDIR/krun-$$"
  mkdir -p "$KR_RUNTIME" && chmod 700 "$KR_RUNTIME"
  export KR_RUNTIME
  # setsid: own process group, so teardown's group-kill can't hit bats itself
  XDG_RUNTIME_DIR="$KR_RUNTIME" setsid dbus-run-session -- bash -c '
    echo "K_BUS=$DBUS_SESSION_BUS_ADDRESS" >"$BUS_ENV"
    echo "K_PID=$DBUS_SESSION_BUS_PID" >>"$BUS_ENV"
    gnome-keyring-daemon --unlock --components=secrets <<<"$KEYRING_PW" >/dev/null 2>&1
    sleep 300
  ' &
  export KEYRING_HOLDER_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$BUS_ENV" ] && grep -q K_PID "$BUS_ENV" 2>/dev/null && break
    sleep 0.1
  done
  [ -s "$BUS_ENV" ] || { kill "$KEYRING_HOLDER_PID" 2>/dev/null; skip "session bus did not start"; }
  # shellcheck disable=SC1090
  source "$BUS_ENV"
  export DBUS_SESSION_BUS_ADDRESS="$K_BUS"
  sleep 1
}

keyring_teardown() {
  # kill the whole holder session (dbus-daemon + keyring + sleep), not just PID
  kill -- -"$KEYRING_HOLDER_PID" 2>/dev/null || kill "$KEYRING_HOLDER_PID" "${K_PID:-}" 2>/dev/null || true
}

teardown() {
  keyring_teardown 2>/dev/null || true
}

make_login() { # <email> <tag> — fabricate the live login on the isolated bus
  TAG="$2" GEMINI_DIR="$AGY_GUARD_GEMINI_DIR" python3 - "$1" <<"PY"
import json, sys, base64, os
email = sys.argv[1]; tag = os.environ["TAG"]; g = os.environ["GEMINI_DIR"]
pay = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
json.dump({"id_token": f"h.{pay}.s", "access_token": f"AT-{tag}",
           "refresh_token": f"RT-{tag}", "token_type": "Bearer",
           "expiry_date": 1, "scope": "s"},
          open(g + "/oauth_creds.json", "w"))
open(g + "/jetski-standalone-oauth-token", "w").write('{"tag":"' + tag + '"}')
open(g + "/google_accounts.json", "w").write('{"active":"' + email + '"}')
PY
  TAG="$2" /usr/bin/python3 - <<"PY"
import secretstorage, os
tag = os.environ["TAG"]
bus = secretstorage.dbus_init()
unlocked = [c for c in secretstorage.get_all_collections(bus) if not c.is_locked()]
coll = unlocked[0]
for it in secretstorage.search_items(bus, {"service": "gemini", "username": "antigravity"}):
    it.delete()
coll.create_item("Password for antigravity on gemini",
                 {"service": "gemini", "username": "antigravity",
                  "xdg:schema": "org.freedesktop.Secret.Generic"},
                 ("live-secret-" + tag).encode(), content_type="text/plain")
PY
}

# ---------------------------------------------------------------- classifier
@test "classify: quota/auth/disabled/unknown map to exits 4/0/5/0" {
  run "$HELPER" classify --text "RESOURCE_EXHAUSTED quota exceeded" --code 1
  [ "$status" -eq 4 ]
  [ "$output" = "quota" ]
  run "$HELPER" classify --text "UNAUTHENTICATED reauth" --code 1
  [ "$status" -eq 0 ]
  [ "$output" = "auth_401" ]
  run "$HELPER" classify --text "account disabled for Terms of Service" --code 1
  [ "$status" -eq 5 ]
  run "$HELPER" classify --text "bogus failure" --code 7
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ---------------------------------------------------------------- add/switch
@test "add registers the live login; mismatched live login stops, never guesses" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered 'a'"* ]]
  run "$HELPER" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a***@example.com"* ]]
  # swap the live login behind the helper's back -> use must STOP, never guess
  make_login b@example.com B
  run "$HELPER" use a
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to guess"* ]]
}

@test "add second account updates active, then forced switch swaps live files and keyring" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  make_login b@example.com B
  run "$HELPER" add b
  [ "$status" -eq 0 ]
  run "$HELPER" current
  [ "$status" -eq 0 ]
  [ "$output" = "b" ]
  run "$HELPER" --force use a
  [ "$status" -eq 0 ]
  [[ "$output" == *"switched b -> a"* ]]
  grep -q '"tag":"A"' "$AGY_GUARD_GEMINI_DIR/jetski-standalone-oauth-token"
  grep -q 'a@example.com' "$AGY_GUARD_GEMINI_DIR/google_accounts.json"
  run /usr/bin/python3 -c 'import secretstorage; bus=secretstorage.dbus_init(); print(list(secretstorage.search_items(bus, {"service":"gemini","username":"antigravity"}))[0].get_secret().decode())'
  [ "$output" = "live-secret-A" ]
  run "$HELPER" verify
  [ "$status" -eq 0 ]
}

@test "use from inside the launcher path is not mistaken for a running agy" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  # simulate the installed launcher path (~/.local/bin/agy) invoking `use`:
  # our own ancestor chain must not trip the running-agy guard
  mkdir -p "$BATS_TEST_TMPDIR/local/bin"
  cp "$HELPER" "$BATS_TEST_TMPDIR/local/bin/agy"
  chmod +x "$BATS_TEST_TMPDIR/local/bin/agy"
  run "$BATS_TEST_TMPDIR/local/bin/agy" --force use a
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on"* ]]
}

@test "quota-hit without a hint still triggers launch-decide ask" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  run "$HELPER" quota-hit
  [ "$status" -eq 0 ]
  run "$HELPER" launch-decide
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "halt"'* ]]
  [[ "$output" == *'"exit": 4'* ]]
}

@test "purge refuses when the live login is a different account" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  make_login b@example.com B
  run "$HELPER" add b
  [ "$status" -eq 0 ]
  # active is b (live B); remove non-active a with --purge must refuse
  # rather than wiping B's live files
  run "$HELPER" remove a --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to delete"* ]]
}

@test "use refuses while an agy process runs" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/fakebin/antigravity-cli"
  printf '#!/bin/sh\nsleep 30\n' >"$BATS_TEST_TMPDIR/fakebin/antigravity-cli/agy"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/antigravity-cli/agy"
  "$BATS_TEST_TMPDIR/fakebin/antigravity-cli/agy" &
  FAKE_PID=$!
  run "$HELPER" --force use a
  kill "$FAKE_PID" 2>/dev/null || true
  wait "$FAKE_PID" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to switch while agy is running"* ]]
}

@test "quota-hit + launch-decide ask; disabled-hit halts rotation (exit 5 path)" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  run "$HELPER" quota-hit --reset-hint 2999-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  run "$HELPER" launch-decide
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "halt"'* ]]  # no alternative registered
  run "$HELPER" disabled-hit
  [ "$status" -eq 0 ]
  run "$HELPER" launch-decide
  [[ "$output" == *'"action": "halt"'* ]]
  [[ "$output" == *'"exit": 5'* ]]
  run "$HELPER" --force use a
  [ "$status" -eq 5 ]
}

@test "backup writes 0600 file; restore --dry-run lists accounts" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  run "$HELPER" backup --out "$BATS_TEST_TMPDIR/bak.json"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/bak.json")" = "600" ]
  run "$HELPER" restore --dry-run "$BATS_TEST_TMPDIR/bak.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would restore 1 account(s): a"* ]]
}

# ---------------------------------------------------------------- launcher
@test "launcher marks quota exhausted (exit 4) without retry" {
  STUB_MODE=quota run "$GUARD" models
  [ "$status" -eq 4 ]
  [[ "$output" == *"marked exhausted, not retried"* ]]
}

@test "launcher halts rotation on 403 (exit 5)" {
  STUB_MODE=disabled run "$GUARD" models
  [ "$status" -eq 5 ]
  [[ "$output" == *"Rotation HALTED"* ]]
}

@test "launcher passes 401 and random failures through unchanged" {
  STUB_MODE=auth run "$GUARD" models
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNAUTHENTICATED"* ]]
  STUB_MODE=fail run "$GUARD" models
  [ "$status" -eq 7 ]
}

@test "accounts prompt prints empty with no state; -- forces CLI pass-through" {
  run "$GUARD" accounts prompt
  [ "$status" -eq 0 ]
  run "$GUARD" -- accounts list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: accounts list"* ]]
}

@test "dead proxy is still refused with exit 3 on launcher and mutation paths" {
  ANTIGRAVITY_PROXY="http://127.0.0.1:9" run "$GUARD" models
  [ "$status" -eq 3 ]
  # offline metadata reads stay usable with no tunnel...
  ANTIGRAVITY_PROXY="http://127.0.0.1:9" run "$GUARD" accounts list
  [ "$status" -eq 0 ]
  # ...but anything that can change the live login still refuses first
  ANTIGRAVITY_PROXY="http://127.0.0.1:9" run "$GUARD" accounts use next
  [ "$status" -eq 3 ]
}

@test "launcher assist halts without TTY on exhausted active, and strips --i-understand-tos-risk" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  make_login b@example.com B
  run "$HELPER" add b
  [ "$status" -eq 0 ]
  # b is active; mark b exhausted while a is ok -> non-TTY launcher must exit 4
  run "$HELPER" quota-hit --reset-hint 2999-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  run "$GUARD" models
  [ "$status" -eq 4 ]
  [[ "$output" == *"not switching without a TTY"* ]]
  # mark b ok and verify --i-understand-tos-risk is stripped before calling $REAL
  run "$HELPER" mark b ok
  [ "$status" -eq 0 ]
  run "$GUARD" --i-understand-tos-risk models
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: models"* ]]
  [[ "$output" != *"--i-understand-tos-risk"* ]]
}

@test "do_switch rolls back live files if write_live fails mid-switch" {
  keyring_setup
  make_login a@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  make_login b@example.com B
  run "$HELPER" add b
  [ "$status" -eq 0 ]
  # Corrupt a's snapshot in accounts.json? No, inject a failure by making
  # oauth_creds.json immutable? Better: test via python importing agy-accounts
  # with write_live raising an error on live_secret_write.
  run /usr/bin/python3 - <<'PY'
import importlib.machinery, importlib.util, os
loader = importlib.machinery.SourceFileLoader("agy_accounts", os.environ["HELPER"])
spec = importlib.util.spec_from_loader("agy_accounts", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
orig = mod.live_secret_write
calls = [0]
def boom(*a, **kw):
    calls[0] += 1
    if calls[0] == 1:
        raise RuntimeError("injected keyring failure")
    return orig(*a, **kw)
mod.live_secret_write = boom
d = mod.load_state()
rc, msg = mod.do_switch(d, "a", force=True)
assert rc == 1 and "live login restored" in msg, (rc, msg)
PY
  [ "$status" -eq 0 ]
  grep -q '"tag":"B"' "$AGY_GUARD_GEMINI_DIR/jetski-standalone-oauth-token"
  grep -q 'b@example.com' "$AGY_GUARD_GEMINI_DIR/google_accounts.json"
}

@test "list --json redacts email local-parts" {
  keyring_setup
  make_login alice@example.com A
  run "$HELPER" add a
  [ "$status" -eq 0 ]
  run "$HELPER" --json list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a***@example.com"* ]]
  [[ "$output" != *"alice@example.com"* ]]
}
