# agy-accounts discovery (Phase 0)

Date: 2026-11-22. Machine: Ubuntu 26.04 / GNOME / Wayland. All `agy`
invocations below went through `agy-guard` with the default proxy
`http://127.0.0.1:10808` (V2rayN). No direct connections. No secret values
are recorded in this document — only shapes, sizes, labels and attribute
names.

**Assumptions.** Single live login today (account A,
`shefvbrian20@gmail.com`); account B does not exist yet on this machine.
`~/.gemini/antigravity-cli/` belongs to the current CLI generation
(`jetski_state.pbtxt`, `settings.json` with no `modelProvider` key).
`busctl --user list` shows `org.freedesktop.secrets` owned by
`gnome-keyring-daemon` (PID 12028).

**Risks.** (1) Login flow for account B is unverified — this report
describes the safe procedure but nobody has performed it. (2) Quota/401/403
shapes are unverified placeholders until Charles injection or a real paste.
(3) Resume-across-accounts is untested for the same reason. (4) Any Python
rewrite must re-prove the fail-closed gate; the current Bash gate is the
reference.

## 1. Backup (done, unencrypted working copy)

Live credential files (all mode 0600) copied with `cp -p` to
`~/.local/state/agy-guard/backups/<UTC-timestamp>/` (dir 0700):

- `oauth_creds.json` (1953 B) — Google OAuth credential: `access_token`,
  `refresh_token`, `token_type`, `expiry_date`, `id_token`, `scope`.
- `jetski-standalone-oauth-token` (1715 B) — JSON `{"token": {...},
  "auth_method": "consumer"}`; inner `token` object keys: `access_token`,
  `token_type`, `refresh_token`, `expiry`, `id_token`, `project_id`.
- `google_accounts.json` (92 B) — `{"active": "<email>", "old": [...]}`.

The spec's `age`/`gpg --symmetric` passphrase-encrypted step is **not done**:
it needs your passphrase (you must supply it or run the command yourself).
Restore was proved only as file copy-back (md5-verified round trip), not via
a throwaway test keyring — also pending your approval to create one.
`login.keyring` itself was never copied.

## 2. Where credentials live

`org.freedesktop.secrets` is owned by `gnome-keyring-daemon` (PID 12028,
`:1.15`). Exactly **one** agy-related item exists in the unlocked `Login`
collection (53 items total):

- label `Password for 'antigravity' on 'gemini'`
- attrs `{service: gemini, username: antigravity,
  xdg:schema: org.freedesktop.Secret.Generic}`
- content-type `text/plain`, secret size 589 bytes (size only, never read).

So: **one account maps to one keyring item + three files**
(`oauth_creds.json`, `jetski-standalone-oauth-token`, `google_accounts.json`).
A before/after-login item diff was impossible (only one account logged in;
no second login performed without your approval). No `strace` was run — the
file set is already fully determined by inspection.

Recommendation for snapshots: capture the 1 keyring secret (via
libsecret/`secretstorage` over D-Bus, stdin/D-Bus only — `secretstorage`
3.5.0 and `dbus-python` 1.4.0 exist on `/usr/bin/python3`; the brew
`python3` lacks them, so feature code must pin `/usr/bin/python3` or add a
dependency) **plus** the 3 files above. `google_accounts.json` is the only
file that names the email in plaintext.

## 3. Identity without a network call: YES

The live email is derivable offline from the `id_token` JWT claim in either
`oauth_creds.json` or the inner `jetski-standalone-oauth-token.token`:

- claims: `iss, azp, aud, sub, email, email_verified, name, picture,
  given_name, family_name, iat, exp, at_hash`
- `email = shefvbrian20@gmail.com`, `email_verified = True`.

`google_accounts.json.active` agrees (`"shefvbrian20@gmail.com"`,
`old: ["brian.shefveland.90@gmail.com"]` — a previous account address still
recorded there). No model call needed. Caveat: `expiry_date`/`exp`
(1795332166000 ms ≈ year 2026) look server-issued and odd; treat expiry as
untrusted, email as trusted.

## 4. Token rotation: NO rotation on read-only calls

`md5sum` of all three files before/after `./agy-guard models` (full model
list, ~8 s, exit 0): **identical**. Keyring secret size unchanged (589 B).
So a read-only `models` call does not rotate anything — but a real model
turn was deliberately **not** tested (spec: model probe is opt-in only).
**Capture-on-switch-out is still required**: assume a normal `agy` turn may
refresh `access_token`/`refresh_token`; the switch algorithm must
re-snapshot the live credentials on every switch-out. Re-verify with a real
turn during implementation (opt-in, proxied).

## 5. Running-process behavior: NOT tested (deliberately)

No `agy`/`agy acp` swap test was run — swapping live credentials under a
running session risks corrupting the only login. What is known: `pgrep`
shows only `antigravity-manager` (Electron) processes, no `agy`/`agy acp`
running now. The spec's rule (refuse switch while any `agy`/`agy acp` runs,
checked via `pgrep` + guard lock) stands on first principles: OAuth file
reads happen at process start / refresh time, so a mid-run swap is at best
ignored and at worst mixed-state. Confirm during implementation against a
stub `agy`, never the live login.

## 6. Quota error shape: UNVERIFIED — fixtures needed

`grep` over `agy-guard` finds no `UNAUTHENTICATED`/quota handling today
(expected — the 401 auto-continue lives in the caller harness, not the
guard). No 429/401/403 was triggered: that requires either your real
quota-exhausted paste or Charles fault injection, neither of which happened
in Phase 0. **Placeholders, not evidence:**

- quota → expect `RESOURCE_EXHAUSTED` / HTTP 429 on stderr, exit code TBD;
- auth → `UNAUTHENTICATED` / 401 (existing auto-continue, unchanged);
- disabled → 403 "disabled ... Terms of Service" (halt rotation).

Next step needs you: **paste a real quota message if you have one**, else
approve Charles injection (HTTP 8887 / SOCKS 8889, upstream 10808) with the
backup from §1 in place.

## 7. Resume across accounts: UNTESTED

`--conversation <uuid>` / `-c` resume flags exist (`agy -- --help`
verified through the guard). Whether a conversation started under A resumes
under B is unknown — testing it needs two live logins. Record the result
here once account B exists. Conversations are per-UUID `.db` files under
`~/.gemini/antigravity-cli/conversations/`; nothing in their names ties
them to an account, so cross-account resume may technically work (policy
question, not a technical block).

## 8. Login flow for account B (procedure, not yet performed)

Safe order (no `/logout`, no revocation): (1) take the §1 backup and prove
restore; (2) register the CURRENT login as account A (`accounts add a` —
snapshot only, no mutation); (3) perform the normal interactive `agy` login
for B in a browser profile dedicated to the B Google account, with exit IP
unchanged (same 10808 tunnel); (4) immediately `accounts add b`; (5) verify
`accounts current` shows B, then `accounts use a` switches back. If step 3
overwrites A's files before step 4, the snapshot from step 2 restores them —
that is exactly what capture-on-switch-out protects.

## 9. Fallback providers: NOT available in settings

`settings.json` keys: `agentMode, allowNonWorkspaceAccess,
artifactReviewPolicy, model, notifications, runningLightSpeed, statusLine,
toolPermission, trustedWorkspaces`. **No `modelProvider`, no `GEMINI_API_KEY`
support.** Per-invocation `--settings` exists (`--settings` flag: "settings
for this session only, never saved") so a fallback could be passed without
mutating the file — but only if the CLI honors a provider key, which is
unverified. Treat the Gemini-key fallback as **unconfirmed**; confirm with
`agy -- --help`/docs or drop it from the design.

## Incidental findings (blockers for any test work)

- The harness environment exports `AGY_GUARD_PROBE_URL=http://127.0.0.1:10808`
  (a proxy URL, not a probe URL). With it set, EVERY `./agy-guard` run fails
  closed with exit 3 (`probe returned HTTP 400`) even though the proxy is
  healthy. With a clean env the default `https://www.google.com/generate_204`
  probe returns 204 through 10808 and `models` works. Implementation must
  unset/ignore a probe URL that equals the proxy URL (or document that the
  harness env breaks the guard). All Phase 0 CLI runs above used
  `env -u AGY_GUARD_PROBE_URL`.
- `agy models --output json` is wrong; correct is bare `agy models` (exit 0,
  table). `verify`/`status --json` envelope confirmed working
  (`{"status":"ok",...}`).
- Spec §5 step 3 ("STOP and ask if live ≠ active") conflicts with §7
  assisted-mode auto-prompt only in that both need the same offline identity
  read — §3 resolves it: compare `id_token.email` against state, no network.

## What Phase 0 did NOT do (needs your approval)

1. Second-account login / item before-after diff / `strace`.
2. `age`-encrypted backup (needs your passphrase) + throwaway-keyring restore proof.
3. Model-turn rotation check, quota/401/403 injection, running-process swap, resume-across-accounts.
4. Any feature code — no `accounts` subcommand exists yet.

**Approval asks:** (a) accept this report as the evidence base; (b) provide a
quota-exhausted message or approve Charles injection; (c) approve the
second-login procedure in §8; (d) confirm Bash (~600 LOC, approaching the
300-LOC `cli-app-generator` escalation point) vs stdlib-only Python helper
for the feature. I recommend the Python-helper-line: keeps the launcher
Bash, puts `accounts` state/crypto logic in one auditable stdlib-only
Python file, no new dependencies beyond `secretstorage` (already present).
