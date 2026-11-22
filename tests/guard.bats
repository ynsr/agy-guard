#!/usr/bin/env bats
# bats suite for agy-guard — hermetic: stub CLI, fake proxy, throwaway $HOME.
#   bats tests/guard.bats        (or: ./tests/run.sh)
#
# Nothing here talks to the real Antigravity CLI or the real network.

setup_file() {
  SRC_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SRC_DIR
  export GUARD="$SRC_DIR/agy-guard"
  PROXY_PORT=$((20000 + RANDOM % 20000))
  export PROXY_PORT
  python3 "$SRC_DIR/tests/fake-proxy.py" "$PROXY_PORT" >"$BATS_FILE_TMPDIR/proxy.log" 2>&1 &
  export PROXY_PID=$!
  for _ in $(seq 1 50); do
    grep -q ready "$BATS_FILE_TMPDIR/proxy.log" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "fake proxy did not start" >&2
  return 1
}

teardown_file() {
  kill "$PROXY_PID" 2>/dev/null || true
}

setup() {
  TMP_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TMP_HOME/.local/bin"
  export HOME="$TMP_HOME"
  export PATH="$HOME/.local/bin:/usr/bin:/bin:$PATH"

  STUB="$BATS_TEST_TMPDIR/stub-cli"
  cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*"
printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-}"
printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-}"
printf 'ALL_PROXY=%s\n' "${ALL_PROXY:-}"
printf 'NO_PROXY=%s\n' "${NO_PROXY:-}"
# traffic for `trace`: one TLS (CONNECT) and one plain-http dial, both optional
curl -s -o /dev/null --max-time 5 https://accounts.example.invalid/x 2>/dev/null || true
curl -s -o /dev/null --max-time 5 http://plain.example.invalid/y 2>/dev/null || true
EOF
  chmod +x "$STUB"
  export ANTIGRAVITY_CLI_BIN="$STUB"

  # plain-http probe through the stub proxy: no CONNECT, no real network
  export ANTIGRAVITY_PROXY="http://127.0.0.1:$PROXY_PORT"
  export AGY_GUARD_PROBE_URL="http://probe.invalid/generate_204"
}

# ---------------------------------------------------------------- guard help
@test "--gh prints the guard help, not the CLI help" {
  run "$GUARD" --gh
  [ "$status" -eq 0 ]
  [[ "$output" == *"fail-closed proxy launcher"* ]]
  [[ "$output" == *"Exit codes: 0 success"* ]]
}

@test "--guard-version prints the guard version only" {
  run "$GUARD" --guard-version
  [ "$status" -eq 0 ]
  [ "$output" = "$("$GUARD" --guard-version)" ]
}

# ---------------------------------------------------------------- pass-through
@test "launcher forwards CLI args verbatim" {
  run "$GUARD" models --output json --effort high
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: models --output json --effort high"* ]]
}

@test "-h is forwarded to the CLI, never intercepted" {
  run "$GUARD" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: -h"* ]]
}

@test "-- passes a management name through to the CLI" {
  run "$GUARD" -- restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: restore"* ]]
}

@test "launcher exports the proxy environment for the CLI" {
  run "$GUARD" anything
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP_PROXY=http://127.0.0.1:$PROXY_PORT"* ]]
  [[ "$output" == *"HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT"* ]]
  [[ "$output" == *"ALL_PROXY=http://127.0.0.1:$PROXY_PORT"* ]]
  [[ "$output" == *"NO_PROXY=localhost,127.0.0.1,::1"* ]]
}

# ---------------------------------------------------------------- fail closed
@test "dead proxy port is refused with exit 3" {
  ANTIGRAVITY_PROXY="http://127.0.0.1:9" run "$GUARD" models
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not reachable"* ]]
  [[ "$output" == *"refusing to run the Antigravity CLI without a working proxy"* ]]
}

@test "non-http proxy scheme is a usage error (exit 2)" {
  ANTIGRAVITY_PROXY="socks5://127.0.0.1:1080" run "$GUARD" models
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be an http(s) proxy URL"* ]]
}

@test "missing CLI binary is a runtime error (exit 1)" {
  ANTIGRAVITY_CLI_BIN="$BATS_TEST_TMPDIR/nope" run "$GUARD" models
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLI binary not found"* ]]
}

@test "open proxy port with no Google egress is refused (exit 3)" {
  # point at the stub proxy but ask for a scheme it cannot serve: CONNECT
  AGY_GUARD_PROBE_URL="https://probe.invalid/generate_204" run "$GUARD" models
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot reach Google"* ]]
}

# ---------------------------------------------------------------- verify
@test "verify reports OK after restore" {
  run "$GUARD" restore
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/agy" ]
  run "$GUARD" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher logic matches this copy"* ]]
  [[ "$output" == *"agy-guard: OK"* ]]
}

@test "verify detects a launcher replaced by a raw ELF binary" {
  "$GUARD" restore >/dev/null
  printf '\177ELF\002\001\001fake' >"$HOME/.local/bin/agy"
  chmod 755 "$HOME/.local/bin/agy"
  run "$GUARD" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"REPLACED BY A RAW ELF BINARY"* ]]
}

@test "verify detects a missing launcher" {
  run "$GUARD" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING — run: agy-guard restore"* ]]
}

@test "verify detects installer PATH lines in shell profiles" {
  "$GUARD" restore >/dev/null
  echo 'export PATH="$HOME/.local/share/antigravity-cli:$PATH"' >>"$HOME/.bashrc"
  run "$GUARD" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"PATH prepends that would shadow the launcher"* ]]
  [[ "$output" == *".bashrc"* ]]
}

@test "doctor is an alias of verify" {
  "$GUARD" restore >/dev/null
  run "$GUARD" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy-guard: OK"* ]]
}

@test "--quiet keeps stdout empty and still returns the verdict" {
  run "$GUARD" verify --quiet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "verify --json emits a cli-hub doctor envelope" {
  "$GUARD" restore >/dev/null
  run "$GUARD" verify --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .status)" = "ok" ]
  [ "$(echo "$output" | jq -r .checks.launcher)" = "ok" ]

  printf '\177ELF\002\001\001fake' >"$HOME/.local/bin/agy"
  run "$GUARD" doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r .status)" = "stale" ]
  [ "$(echo "$output" | jq -r .checks.launcher)" = "replaced-by-binary" ]

  rm -f "$HOME/.local/bin/agy"
  run "$GUARD" verify -o json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r .status)" = "missing" ]
}

# ---------------------------------------------------------------- trace
@test "trace records the domains the CLI dials and writes a JSON summary" {
  LOG="$BATS_TEST_TMPDIR/trace.jsonl"
  run "$GUARD" trace --log-file "$LOG"
  [ "$status" -eq 0 ]
  [ -f "$LOG" ]
  grep -q 'accounts.example.invalid' "$LOG"
  grep -q 'plain.example.invalid' "$LOG"
  SUM="${LOG%.jsonl}.summary.json"
  [ -f "$SUM" ]
  [ "$(jq -r '.domains | length' "$SUM")" = "2" ]
  [ "$(jq -r '.upstream_proxy' "$SUM")" = "http://127.0.0.1:$PROXY_PORT" ]
  [ "$(jq -r '.domains[0].kind' "$SUM")" = "connect" ]
}

@test "trace points the CLI at the logging proxy, never directly at the tunnel" {
  LOG="$BATS_TEST_TMPDIR/env.jsonl"
  run "$GUARD" trace --log-file "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP_PROXY=http://127.0.0.1:"* ]]
  [[ "$output" != *"HTTP_PROXY=http://127.0.0.1:$PROXY_PORT"* ]]
}

@test "trace passes CLI arguments after -- through" {
  LOG="$BATS_TEST_TMPDIR/args.jsonl"
  run "$GUARD" trace --log-file "$LOG" -- models --effort high
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS: models --effort high"* ]]
}

@test "trace --json appends the summary JSON and refuses a dead upstream" {
  LOG="$BATS_TEST_TMPDIR/json.jsonl"
  run "$GUARD" trace --log-file "$LOG" --json
  [ "$status" -eq 0 ]
  # CLI output comes first; the summary object follows on stdout
  [[ "$output" == *'"tool": "agy-guard trace"'* ]]
  [ "$(jq -r '.domains | length' "${LOG%.jsonl}.summary.json")" = "2" ]

  ANTIGRAVITY_PROXY="http://127.0.0.1:9" run "$GUARD" trace --log-file "$BATS_TEST_TMPDIR/dead.jsonl"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not reachable"* ]]
}

# ---------------------------------------------------------------- restore
@test "restore strips installer PATH lines and is idempotent" {
  echo 'export PATH="/home/bs/.local/share/antigravity-cli:$PATH"' >>"$HOME/.bashrc"
  run "$GUARD" restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"stripped 1 PATH line(s)"* ]]
  ! grep -q 'antigravity-cli:$PATH' "$HOME/.bashrc"
  run "$GUARD" restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"already identical to this copy"* ]]
}

@test "restore --dry-run changes nothing" {
  run "$GUARD" restore --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would write"* ]]
  [ ! -e "$HOME/.local/bin/agy" ]
}

# ---------------------------------------------------------------- install.sh
@test "install.sh --dry-run creates nothing, real install is usable and idempotent" {
  export AGY_GUARD_INSTALL_DIR="$BATS_TEST_TMPDIR/bin"
  run "$SRC_DIR/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would:"* ]]
  [ ! -e "$AGY_GUARD_INSTALL_DIR/agy-guard" ]

  run "$SRC_DIR/install.sh" --yes
  [ "$status" -eq 0 ]
  [ -x "$AGY_GUARD_INSTALL_DIR/agy-guard" ]

  run "$AGY_GUARD_INSTALL_DIR/agy-guard" --guard-version
  [ "$output" = "$("$GUARD" --guard-version)" ]

  run "$SRC_DIR/install.sh" --yes
  [ "$status" -eq 0 ]
}

@test "install.sh --link symlinks and uninstall removes only our install" {
  export AGY_GUARD_INSTALL_DIR="$BATS_TEST_TMPDIR/bin2"
  run "$SRC_DIR/install.sh" --link --yes
  [ "$status" -eq 0 ]
  [ -L "$AGY_GUARD_INSTALL_DIR/agy-guard" ]

  run "$SRC_DIR/install.sh" uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$AGY_GUARD_INSTALL_DIR/agy-guard" ]

  # a foreign file must not be removed
  mkdir -p "$AGY_GUARD_INSTALL_DIR"
  printf '#!/bin/sh\necho foreign\n' >"$AGY_GUARD_INSTALL_DIR/agy-guard"
  run "$SRC_DIR/install.sh" uninstall
  [ "$status" -eq 1 ]
  [ -f "$AGY_GUARD_INSTALL_DIR/agy-guard" ]
}
