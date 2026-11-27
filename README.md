# agy-guard

Fail-closed proxy launcher and repair tool for the **Antigravity CLI** (`agy`).

Every Antigravity CLI invocation must leave the machine through the local proxy
(`http://127.0.0.1:10808` by default). Running it with a direct connection
risks an account ban, so `agy-guard` refuses to start at all when the tunnel is
not usable — instead of quietly running the CLI outside it. It also carries the
repair path for the two ways the guard can get lost: the CLI's own installer
prepending a PATH entry, and a reinstall replacing `~/.local/bin/agy` with the
raw CLI binary.

```
~/.local/bin/agy          the launcher (installed by this repo)
~/.local/bin/agy-guard    this tool: same launcher + restore/verify/status
~/.local/share/antigravity-cli/agy   the real CLI binary (never run directly)
```

## How the launcher works

Called with any CLI argument (or none), `agy-guard` / `agy`:

1. checks the real CLI binary exists and is executable (exit 1 if not);
2. checks `ANTIGRAVITY_PROXY` is an `http(s)` URL (exit 2 if not);
3. opens a TCP connection to the proxy (exit 3 if refused);
4. sends one real request through the proxy to Google and requires a 2xx/3xx
   (retried once, 15 s each — the tunnel is sometimes slow; exit 3 on failure);
5. exports `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` (and lowercase forms) plus
   `NO_PROXY=localhost,127.0.0.1,::1`, then `exec`s the CLI with **all original
   arguments untouched**.

There is deliberately **no flag or environment variable that skips the checks**
or falls back to a direct connection.

### Arguments belong to the CLI

`-h`, `--help`, `help` and `--version` are **not** intercepted — they go to the
CLI, exactly as if you had typed `agy -h`. The guard's own help and version have
their own flags:

```bash
agy-guard --guard-help      # or --gh
agy-guard --guard-version
agy-guard -- restore        # force pass-through for a management name
```

### Exit codes

| code | meaning |
|------|---------|
| 0 | success |
| 1 | runtime error (CLI binary missing, write failure) |
| 2 | usage error (bad proxy URL, unknown option for a management command) |
| 3 | proxy/precondition failure — refused to run without a working tunnel |
| 4 | account condition — quota-exhausted, or nothing to switch to (never retried) |
| 5 | account disabled (Terms of Service) — rotation halted, clear with `accounts mark <name> ok --ack` |

## Commands

| command | purpose |
|---------|---------|
| `agy-guard restore [--dry-run]` | rewrite `~/.local/bin/agy` from this file and strip installer PATH lines that would shadow it |
| `agy-guard verify` | compare the installed launcher with this copy, check `agy` PATH resolution and shell profiles (exit 1 on any problem) |
| `agy-guard status` | verify + real CLI binary path/size/version (version read through the launcher, never the raw binary) |
| `agy-guard doctor` | alias of `verify` (`cli-hub doctor` contract) |
| `agy-guard trace [opts] [-- cli args]` | run the CLI proxied through a **chained logging proxy** and record every domain it dials |
| `agy-guard start --endpoint URL --model ID [--api-key KEY] [--defaults] [-- cli args]` | one-shot session against a temporary OpenAI-compatible endpoint (gateway mode); exports `AGY_LLM_GATEWAY_*` for the child only, never touches `settings.json` |
| `agy-guard --guard-help` / `--gh` | guard help |
| `agy-guard --guard-version` | guard version |
| `agy-guard <args…>` | identical to `agy <args…>`: proxied, checked, forwarded |
| `agy-guard accounts list [--json]` | registered accounts, state, reset hints (`*` = active) |
| `agy-guard accounts current [--json]` | active account name |
| `agy-guard accounts add <name>` | register the CURRENT live login as `<name>` (snapshot only) |
| `agy-guard accounts capture [name]` | snapshot the live login into the active/matching entry (or register it if new) |
| `agy-guard accounts use <name\|next> [--force]` | switch the live login (30-min dwell unless `--force`) |
| `agy-guard accounts mark <name> ok\|exhausted\|disabled [--until ISO8601] [--ack]` | set state; `--ack` clears a rotation halt |
| `agy-guard accounts remove <name> [--purge] [--dry-run]` | delete a snapshot (`--purge` also wipes live files) |
| `agy-guard accounts verify [--json]` | snapshot integrity, identity, perms, proxy |
| `agy-guard accounts backup --out FILE [--dry-run]` | credential bundle (**plaintext**, mode 0600 — encrypt with age/gpg immediately) |
| `agy-guard accounts restore FILE [--dry-run]` | restore snapshots from a bundle |
| `agy-guard accounts prompt` | active account name (cheap, for the shell prompt) |

Options: `--quiet/-q` (no human output, exit code only), `--json` (machine
readable result, see below), `--dry-run` (restore/remove/backup),
`--force` (`accounts use`: skip the dwell wait). `--` forces CLI
pass-through if the CLI ever gains an `accounts` subcommand of its own.

`--json` emits the `cli-hub doctor` envelope:

```json
{"status":"ok","message":"launcher, PATH and shell profiles are consistent",
 "checks":{"launcher":"ok","path":"ok","profiles":"ok"}}
```

`status` is `ok`, `stale` (something needs repair) or `missing`; the exit code
still carries the verdict.

## Starting with a temporary custom endpoint

`agy-guard start` runs one `agy` session against a temporary OpenAI-compatible
endpoint and throws everything away when the session ends — `settings.json` is
never touched. It uses the CLI's gateway mode (`AGY_LLM_GATEWAY_*`, exported
for the child only) plus the session-only `--model` flag, and runs the same
fail-closed proxy gate as the launcher first.

```bash
agy-guard start --endpoint http://localhost:11434/v1 --model llama3.1
agy-guard start --defaults                       # endpoint http://localhost:7698/v1,
                                                  # model cline-pass/cline-pass/muse-spark-1.3-contributor
agy-guard start --endpoint URL --model ID -p "hi" # extra args go to the CLI
```

| option | meaning |
|--------|---------|
| `--endpoint URL` | custom endpoint root; one trailing `/v1` is stripped (the gateway appends paths itself). Required unless `--defaults` |
| `--model ID` | model id sent verbatim to the gateway. Required unless `--defaults` |
| `--api-key KEY` | gateway API key; overrides `AGY_LLM_GATEWAY_API_KEY`. Both optional — omit both for a keyless local gateway |
| `--defaults` | use `AGY_GUARD_DEFAULT_ENDPOINT` / `AGY_GUARD_DEFAULT_MODEL` (or the bundled defaults); conflicts with `--endpoint`/`--model` |

Rules: unknown flags (`-p`, `--sandbox`, …) are forwarded to the CLI untouched
(`--` still forces verbatim pass-through); a `settings.json` with
`modelProvider` set is refused with exit 2 (gateway mode needs that key
absent); Google-account assist and quota classification are skipped — the
session never mutates account state.

## Tracing what the CLI dials

`agy-guard trace` answers "which domains does the CLI talk to, and does it ever
escape the tunnel?". It starts a small chained logging proxy on a random
loopback port, points the CLI's `HTTP(S)_PROXY`/`ALL_PROXY` at it, and forwards
every connection to the real proxy — so the session stays proxied end to end
while each requested host is recorded.

```bash
agy-guard trace                     # interactive CLI, log under ~/.local/state/agy-guard/
agy-guard trace --log-file /tmp/agy.jsonl
agy-guard trace -- --help           # args after -- go to the CLI
```

| option | meaning |
|--------|---------|
| `--log-file F` | JSONL, one line per proxied connection (`ts`,`host`,`port`,`kind`). Default `~/.local/state/agy-guard/trace-<UTC>.jsonl` |
| `--summary F` | JSON report written when the session ends. Default `<log>.summary.json` |
| `--upstream URL` | real proxy to forward to (default `$ANTIGRAVITY_PROXY`) |
| `--json` | also print the summary object to stdout after the CLI exits |

Two files come out of a session:

- `<log>.jsonl` — append-only stream, safe if the process is killed.
- `<log>.summary.json` — deduplicated report: per-domain `count`, `first_seen`,
  `last_seen`, plus `direct_connections`.

`direct_connections` is the leak detector: a watchdog samples the CLI's socket
table once a second and records any non-loopback peer, i.e. traffic that did
**not** go through the logger (and therefore not through the tunnel). An empty
list means every observed connection was proxied.

The upstream proxy is validated with the same fail-closed probe as the launcher
before anything starts, so a dead tunnel refuses with exit 3 instead of running
the CLI unproxied.

## Install / uninstall

```bash
./install.sh                 # copy agy-guard into ~/.local/bin
./install.sh --restore       # …and rewrite ~/.local/bin/agy from the guard
./install.sh --link          # symlink instead of copy (follows repo edits)
./install.sh --dry-run       # preview, change nothing
./install.sh uninstall       # remove the installed agy-guard (only if ours)
AGY_GUARD_INSTALL_DIR=~/bin ./install.sh
```

A **copy** is the default on purpose: the guard has to survive the repo being
moved or deleted together with an accidental CLI reinstall. Install is
idempotent; a file that is not a previous install is only replaced after
confirmation (`--yes` for non-interactive runs). Uninstall never touches
`~/.local/bin/agy` — that is the CLI launcher, and removing it silently would
remove the proxy enforcement.

`install.sh` ends with a best-effort `cli-hub register` (and uninstall runs
`cli-hub unregister`), so the guard shows up in `cli-hub list`. It also writes an
install receipt (`~/.local/share/agy-guard/install-receipt.json`), which is what
lets `cli-hub doctor agy-guard` run `agy-guard doctor --json` and report the
live verdict:

```
│ agy-guard │ ok │ launcher, PATH and shell profiles are consistent │
```

## Recovery runbook

After anything that touches the Antigravity CLI (a version bump, a reinstall, a
new shell that behaves oddly):

```bash
agy-guard verify          # 0 = healthy
agy-guard restore         # repair: rewrite the launcher, strip PATH prepends
agy --version             # confirm the CLI still answers through the proxy
```

`verify` detects: launcher missing, launcher replaced by a raw ELF binary,
launcher logic drifted from this copy, a PATH entry shadowing `agy`, and
`export PATH="…/antigravity-cli:$PATH"` lines in `.bashrc`, `.zshrc`,
`.bash_profile` or `.profile`.

## Tests

```bash
bats tests/guard.bats       # 33 tests, hermetic
bats tests/accounts.bats    # 17 tests: classifier, isolated-keyring
                            # add/switch/rollback/quota/403/backup + launcher assist/exits
```

The suite uses a stub CLI and a stub HTTP proxy on loopback with a plain-HTTP
probe URL (`AGY_GUARD_PROBE_URL`), so it needs no real network and never talks
to the real Antigravity CLI. It covers: argument pass-through (including `-h`,
`--`, management-name collisions), proxy environment export, the three refusal
paths (exit 1/2/3), `verify` detection of a missing/replaced/drifting launcher,
PATH shadowing, shell-profile repair, `--json`/`--quiet`, and `install.sh`
install/link/uninstall idempotency.

## Caveats

- The proxy probe costs ~1–2 s per invocation (worst case ~30 s when the tunnel
  is half-broken: two 15 s attempts before refusing). That is the price of never
  starting unproxied.
- `restore` intentionally overwrites `~/.local/bin/agy`; it is a repair tool.
  It supports `--dry-run`.
- The CLI self-updates in place (`~/.local/share/antigravity-cli/agy`) and its
  background update path inherits the proxied environment. `agy install` — and a
  fresh run of the official installer — re-adds the PATH prepend that shadows
  the launcher; that is the case `restore` fixes, and `agy install --skip-path`
  avoids it in the first place.
- The generated conformance gate (`cli-app-generator`'s `verify-cli`) reports
  three deliberate deviations: `--help` does not document exit codes, an unknown
  subcommand is the CLI's error (not a JSON envelope), and there is no
  pick-gated command. All three follow from being a pass-through launcher rather
  than a data CLI; the machine-checkable parts (exit codes, stdout purity,
  non-blocking, no ANSI, `--output json`) pass.
- Behaviour change from the ad-hoc version this tool replaced: proxy refusal
  used to exit `78`; it is now `3` (network/precondition), per the repo
  convention.
- Multi-account rules (see `docs/agy-accounts-discovery.md`): one account at a
  time, never concurrent use; quota state comes only from errors the official
  CLI itself emits — no quota-API polling or scraping; account B is added by a
  normal interactive `agy` login while A's snapshot is already stored (never
  `/logout`, never revoking); auto-switching ships disabled and needs config
  plus `--i-understand-tos-risk`; manual switching between your own paid
  accounts is fine, automated cycling to dodge quota is a ToS violation.
