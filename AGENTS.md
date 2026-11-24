# agy-guard — Agent context

Primary audience: Humans — a terminal launcher and repair tool; its own output is
plain human text. `verify`/`status`/`doctor` accept `--json` (cli-hub doctor
envelope) and `--quiet` for scripts, and everything else the tool prints is the
Antigravity CLI's own output, forwarded untouched.

## What this is

`agy-guard` is two things in one file:

1. the **launcher** installed as `~/.local/bin/agy` (invoked as `agy`): fail-closed
   proxy checks, then `exec` the real CLI with the proxy environment set;
2. the **repair tool** (invoked as `agy-guard`): `restore`, `verify`, `status`,
   `doctor`, `trace`, `--guard-help`, `--guard-version`.

The real CLI binary lives at `~/.local/share/antigravity-cli/agy` and must never
be executed directly (no proxy enforcement).

## Non-negotiables

- **Never intercept `-h`, `--help`, `help`, `--version`.** They belong to the
  CLI. The user explicitly requires `agy-guard -h` to be `agy -h`; the guard's
  own help is `--guard-help` / `--gh`.
- **Never add a bypass** (env var, flag, `--no-proxy`, fallback-to-direct). If
  the proxy or the Google egress probe fails, the tool must refuse (exit 3).
- **Fail closed, always.** Checks run before `exec`; nothing may run the CLI
  without the exported `HTTP(S)_PROXY`/`ALL_PROXY` + `NO_PROXY` environment.
- **`restore` writes `~/.local/bin/agy` from this file.** Keep the launcher body
  between `[ -x "$REAL" ] || {` and `exec "$REAL" "$@"` readable by
  `launcher_fingerprint()` (a `sed` range) — `verify` compares installed copies
  with it, and `install.sh` uses the same range to recognise its own installs.
- **`trace` never `exec`s.** It must stay the parent so it can stop the logging
  proxy and write the summary; the CLI runs as a child with `HTTP(S)_PROXY`
  pointed at the chained logger, which forwards to `$ANTIGRAVITY_PROXY`. Never
  point the child straight at the tunnel and "log" separately — the logger is
  what both records and proxies.
- `trace`'s upstream must pass the same `assert_proxy_ok` gate as the launcher;
  a broken upstream is exit 3, never an unproxied run.
- Exit codes: `0` ok · `1` runtime · `2` usage · `3` proxy/precondition.
- `assert_proxy_ok` is defined above `do_trace` on purpose: the dispatch block
  runs before the bottom-of-file launcher section, so anything the management
  commands call must already be defined.

## Files

| file | responsibility |
|------|----------------|
| `agy-guard` | launcher + management commands (single-file bash; deps: coreutils, curl, python3 — python3 runs the embedded `trace` proxy and rewrites one rc file) |
| `install.sh` | copy/symlink into `~/.local/bin`, `--restore`, `--dry-run`, `--yes`, `--link`, `uninstall`, install receipt (`~/.local/share/agy-guard/install-receipt.json`), `cli-hub register/unregister` |
| `tests/guard.bats` | 33 hermetic bats tests (stub CLI + stub proxy, no real network); the stub also dials two `.invalid` hosts through the logger to exercise `trace` |
| `tests/fake-proxy.py` | loopback proxy answering 204 to every request, used with `AGY_GUARD_PROBE_URL=http://…` |

## Build / test

```bash
cd /home/bs/projects/personal/agy-guard
bats tests/guard.bats          # full suite, offline
bash -n agy-guard install.sh   # syntax
./install.sh --dry-run         # preview install
./install.sh --yes --restore   # install + rewrite ~/.local/bin/agy
agy-guard verify --json        # live health ({"status":…})
```

`restore`/`verify` in tests run against a throwaway `$HOME`, so they never touch
the real `~/.local/bin` — keep it that way (never hardcode `/home/bs` paths).

## Environment overrides

| var | default | use |
|-----|---------|-----|
| `ANTIGRAVITY_PROXY` | `http://127.0.0.1:10808` | proxy URL; must be `http(s)` |
| `ANTIGRAVITY_CLI_BIN` | `~/.local/share/antigravity-cli/agy` | real CLI path (tests use a stub) |
| `AGY_GUARD_PROBE_URL` | `https://www.google.com/generate_204` | egress probe; the bats suite points it at the stub proxy over plain HTTP |
| `AGY_GUARD_INSTALL_DIR` | `~/.local/bin` | `install.sh` target |

## Conformance notes (`cli-app-generator` / `verify-cli`)

Accepted deviations, all consequences of being a pass-through launcher:

- check 1a — `--help` is the CLI's help and does not document this tool's exit
  codes (documented in `README.md` and `--guard-help` instead);
- check 6 — an unknown subcommand is forwarded to the CLI, so the error is the
  CLI's, not a JSON envelope;
- check 9 — no pick-gated command exists.

Green: exit codes, stdout purity, `--output json`/`--json` (doctor envelope),
non-blocking on non-TTY, no ANSI (never colourised).

## Related

Skill: `cli-app-generator` (repo conventions: exit codes 0/1/2/3, stdout = data
only, idempotent installers, AGENTS.md + README per tool). Sibling tools:
`tools/box-unwrap` (single-file script + install.sh), `tools/cli-hub`
(registry/doctor that `install.sh` registers into).
