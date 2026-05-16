# Claude / Codex / Vibe usage metrics → NATS

Status: draft v2 — incorporates first round of feedback.
Owner: Sandstorm
Date: 2026-05-16

## Goal

For every interaction the user has with Claude Code or Codex (OpenAI), emit
a small metrics event to a central NATS server. From the aggregated stream
we want to answer:

- How long are sessions (per tool, per user, per host)?
- How many tokens are spent (input / output / cache-read / cache-write)?
- How much of the user's plan quota is left (when the tool exposes it)?

Vibe (Mistral) is **out of scope for v1** — it has no real hook surface and
we won't wrap the binary just for this.

The collector must be a thin shim — never block the agent, never leak
secrets, and degrade silently if NATS is unreachable.

## Distribution

Shipped as a new Homebrew formula in this tap, modeled after
`Formula/claude-safe.rb`:

- Formula name: `claude-metrics` (separate from `claude-safe`)
- Dependencies: `nats-io/nats-tools/nats` (the `nats` CLI), `jq`
- Installs:
  - `bin/claude-metrics-emit` — one-shot publisher (bash + `jq` + `nats`).
    Called from hooks; reads the hook payload on stdin, publishes one
    NATS message, exits.
  - `bin/claude-metrics-install-hooks` — explicit, idempotent installer
    that wires the emitter into Claude Code's `~/.claude/settings.json`
    and Codex's `~/.codex/config.toml`. **Not auto-run** on `brew install`
    (Homebrew post-install editing user dotfiles is too magical and
    unreliable across machines).
  - `share/claude-metrics/` — template snippets and a README.
- Caveats: print the two commands needed to (a) run the hook installer and
  (b) verify NATS connectivity.

## NATS connection

Single config file at `~/.config/claude-metrics/nats.conf` (key=value):

```
NATS_URL=tls://nats.example:4222
NATS_SUBJECT_PREFIX=metrics.agents
NATS_NKEY=SUAEXAMPLE...     # nkey seed inline
```

The emitter sources this file and publishes via:

```
nats --server "$NATS_URL" --nkey <(printf '%s' "$NATS_NKEY") \
     pub "$subject" "$payload"
```

(The `<(…)` form keeps the seed off disk; if `nats` requires a real file
we use `mktemp` + `trap rm`.)

If the conf file is missing or unreadable → `exit 0` silently. Not
configuring it == opting out.

## Async publish

NATS publish can block (TLS handshake, DNS, etc). To guarantee hooks never
slow down the agent:

```
( timeout 2s nats … pub … >/dev/null 2>&1 & )
disown 2>/dev/null || true
```

Fire-and-forget. On failure, the event is dropped — **no on-disk spool**,
no retries. Set `CLAUDE_METRICS_DEBUG=1` to surface errors on stderr.

## Subject scheme

Hierarchical, including host and user — good for `nats sub` filtering and
ACLs later:

```
<prefix>.<tool>.<event>.<host>.<user>
```

Example: `metrics.agents.claude.prompt.macbook-seb.seb`

Events:

- `session_start` — Claude Code `SessionStart` hook
- `prompt` — Claude Code `UserPromptSubmit` hook
- `stop` — end-of-turn (Claude `Stop` hook / Codex `notify`) — carries
  cumulative session token totals
- `session_end` — Claude Code `SessionEnd` hook

End-of-turn is enough for Codex; no extra wrapping needed.

## Event payload — flat JSON for ClickHouse

The target ClickHouse table is `sandstorm_monitoring_v2_db.full_logs`. Our
JSON must be ingestible as-is. The standard columns are filled at the top
level and any tool-specific fields are added as additional **flat** keys
(no nested objects). `message` is **not** populated as a separate
field — we don't have a human log line to log.

Standard fields (mapped to the table's columns):

| Field               | Example                        | Notes                                                               |
|---------------------|--------------------------------|---------------------------------------------------------------------|
| `customer_tenant`   | `"sandstorm"`                  | constant for v1 — from `nats.conf` (`CUSTOMER_TENANT=`)             |
| `customer_project`  | `"sandstorm.ai-metrics"`       | constant — from `nats.conf` (`CUSTOMER_PROJECT=`)                   |
| `host_group`        | `"laptops"`                    | from `nats.conf` (`HOST_GROUP=`)                                    |
| `host_name`         | `"macbook-seb"`                | `hostname -s`                                                       |
| `event_module`      | `"agent-metrics"`              | constant                                                            |
| `event_dataset`     | `"agent-metrics.claude.stop"`  | `<event-module>.<tool>.<event>`                                     |
| `timestamp`         | `"2026-05-16 10:11:12.345678"` | DateTime64(6) — UTC, space separator, microseconds !!!!! MUST BE A  |
| `level`             | `"info"`                       | always `info`; `error` only if we emit a self-error                 |
| `event_duration_ms` | `12345`                        | session age in ms on `stop` / `session_end`; null otherwise         |
| `event_original`    | `"{…raw hook payload JSON…}"`  | the unmodified hook stdin payload, as a string                      |

            #################
            # 2) Processing: timestamp_rfc3339 -> timestamp
            #################
            if exists(.timestamp_rfc3339) {
                # format: https://docs.rs/chrono/latest/chrono/format/strftime/index.html#specifiers
                # example source: "2023-01-18T12:33:54.861647424Z" -> 6 fractional digits
                parsed, err = parse_timestamp(.timestamp_rfc3339, "%+")
                if err == null {
                .timestamp = format_timestamp!(parsed, format: "%s%6f")
                }
            }


=> timestamp_rfc3339 EMITTED??? (Better human readable?)

Additional flat fields (no nesting):

```json
{
  "tool":               "claude",
  "tool_version":       "1.0.123",
  "event":              "stop",
  "session_id":         "9c2f...",
  "user":               "seb",
  "model":              "claude-opus-4-7",

  "tokens_input":       12400,
  "tokens_output":      3800,
  "tokens_cache_read":  184200,
  "tokens_cache_write": 0,

  "quota_plan":              "max-20x",
  "quota_five_hour_pct_used": 42,
  "quota_weekly_pct_used":    17,
  "quota_source":             "local"
}
```

Notes on the new shape:

- **No `user_hash`, no `cwd_hash`** — we send the real `$USER`. cwd is not
  sent at all. => CWD HASH IS GOOD.
- **Tokens are flat** (`tokens_input`, …) for ClickHouse columnar use.
- **Tokens are absolute, cumulative per session** — not deltas. The
  emitter reads the transcript's latest cumulative `usage` totals and
  sends those. The aggregation side can compute differences if needed. => IS THIS WHAT EXISTS NATIVELY? I DONT WANT COMPUTE
- **Session IDs are never invented.** If the tool didn't give us one, we
  omit the field. (This rules out Vibe for v1 anyway.)
- **Quota** is read opportunistically from local files (Claude Code's
  `~/.claude/.usage.json` or whatever the current path is — to be verified
  at implementation time). If absent, the four `quota_*` fields are
  omitted. **No separate launchd / cron tick** — quota piggy-backs on
  `stop` events only. RESEARCH HOW THIS WORKD

## Hook points per tool

### Claude Code

Native hooks in `~/.claude/settings.json`. The installer merges:

```jsonc
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command",
        "command": "claude-metrics-emit session_start",
        "_managed_by": "sandstorm-claude-metrics" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
        "command": "claude-metrics-emit prompt",
        "_managed_by": "sandstorm-claude-metrics" }] }],
    "Stop":             [{ "hooks": [{ "type": "command",
        "command": "claude-metrics-emit stop",
        "_managed_by": "sandstorm-claude-metrics" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command",
        "command": "claude-metrics-emit session_end",
        "_managed_by": "sandstorm-claude-metrics" }] }]
  }
}
```

The installer:

1. Reads existing `settings.json`.
2. Strips any prior entries tagged `"_managed_by": "sandstorm-claude-metrics"`.
3. Appends the four entries above.
4. Writes back atomically (`mktemp` + `mv`).

This way, the installer is idempotent and never clobbers user-managed
hooks.

The hook payload on stdin (`{session_id, transcript_path, cwd, …}`) is
forwarded into `event_original`. The emitter reads `transcript_path` to
pull the latest cumulative usage totals.

### Codex (OpenAI)

End-of-turn is enough. The installer sets in `~/.codex/config.toml`:

```toml
notify = ["claude-metrics-emit", "codex-notify"]
```

Codex invokes this at end-of-turn with a JSON arg describing the event.
We map that to a `stop` event. Token totals come from the latest message's
`usage` field in the active session JSONL under `~/.codex/sessions/`.

No session-start / session-end events for Codex in v1 — we accept the
coarser data and avoid wrapping the binary.

If the user has an existing `notify = […]` line, the installer refuses to
overwrite it and prints a diff for manual merge. (Editing arbitrary TOML
arrays automatically is more risk than reward.)

### Vibe (Mistral)

**Skipped in v1.** Revisit when Vibe ships a hook system.

## Failure & performance

- Emitter runs async via `( … & ) disown` — returns immediately.
- The detached `nats pub` is wrapped in `timeout 2s`. On timeout or
  network error the event is dropped silently.
- No on-disk spool, no retries. Drop is acceptable.
- stderr is `/dev/null` unless `CLAUDE_METRICS_DEBUG=1`.

## v1 scope (frozen)

- `claude-metrics` formula in this tap (separate from `claude-safe`).
- Bash emitter: `jq` for JSON, `nats` CLI for publish, fully async.
- Claude Code: 4 hooks (`SessionStart`, `UserPromptSubmit`, `Stop`,
  `SessionEnd`), tagged `_managed_by: sandstorm-claude-metrics`.
- Codex: `notify` only → `stop` events.
- Vibe: not supported.
- Explicit `claude-metrics-install-hooks` command (no auto-edit).
- Flat JSON payload matching `sandstorm_monitoring_v2_db.full_logs`,
  with `event_original` carrying the raw hook payload.
- Cumulative, per-session token totals (not deltas).
- Quota piggy-backed on `stop` if locally available; no daemon / cron.
- Subject: `<prefix>.<tool>.<event>.<host>.<user>`.
- Config: single `~/.config/claude-metrics/nats.conf` with `NATS_URL`,
  `NATS_SUBJECT_PREFIX`, `NATS_NKEY`, `CUSTOMER_TENANT`,
  `CUSTOMER_PROJECT`, `HOST_GROUP`. Missing file = opt-out.

## Still to nail down before coding

1. Exact location & format of Claude Code's local quota file
   (`~/.claude/.usage.json`? something else?). If we can't find it,
   `quota_*` fields are simply omitted.
2. Exact JSON shape Codex's `notify` script receives — we need this to
   pull `session_id`, model, and usage out of one invocation.
3. Whether `nats` CLI accepts the nkey seed via process substitution
   (`<(…)`) or insists on a real file. If real-file only, the emitter
   writes it to `mktemp -t claude-metrics-nk` with mode 600 and
   `trap rm` cleanup.

Once these three are confirmed during implementation, the formula and
emitter ship in a single PR.
