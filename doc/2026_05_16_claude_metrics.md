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

  "tokens_turn_input":                  12400,
  "tokens_turn_output":                 3800,
  "tokens_turn_cache_read":             184200,
  "tokens_turn_cache_creation_claude":  39431,

  "message_id":  "msg_01McrpjozbZ1b6V1oG7E9CVz",
  "request_id":  "req_011CZ6XLQqJa288HCLBsF5ss"
}
```

Notes on the new shape:

- **Identity**: real `$USER`, plus a `cwd_hash` (sha256 of the absolute
  working directory) so we can count distinct projects without leaking
  paths or repo names. No `user_hash`.
- **Tokens are flat** (`tokens_turn_input`, …) for ClickHouse columnar use.
- **Tokens are per-turn**, named explicitly with the `tokens_turn_` prefix
  so nobody can confuse them with cumulative totals. This is what every
  tool exposes natively — no compute on our side. ClickHouse `SUM()` gives
  the cumulative-per-session figure when needed.
- **Claude Code is the reference**: field semantics follow its transcript
  `usage` block exactly. Other tools are mapped to those names. If a tool
  doesn't expose a given subfield (e.g. Codex has no `cache_creation`),
  we emit `0`. Mapping:

  Common (cross-tool) fields — no suffix:

  | Field                    | Claude transcript               | Codex rollout (`payload.type = token_count`) |
  |--------------------------|---------------------------------|----------------------------------------------|
  | `tokens_turn_input`      | `usage.input_tokens`            | `info.last_token_usage.input_tokens`         |
  | `tokens_turn_output`     | `usage.output_tokens`           | `info.last_token_usage.output_tokens`        |
  | `tokens_turn_cache_read` | `usage.cache_read_input_tokens` | `info.last_token_usage.cached_input_tokens`  |

  Tool-specific fields — suffixed with the tool name so they can never be
  mistaken for cross-tool numbers (and so a `SUM()` query can pick them up
  by suffix):

  | Field                                  | Source tool | Source field                                    |
  |----------------------------------------|-------------|-------------------------------------------------|
  | `tokens_turn_cache_creation_claude`    | Claude      | `usage.cache_creation_input_tokens`             |
  | `tokens_turn_reasoning_output_codex`   | Codex       | `info.last_token_usage.reasoning_output_tokens` |

  Fields are only emitted when the source tool produces them — i.e. a
  Codex event will not carry `tokens_turn_cache_creation_claude` at all
  (rather than emitting `0`). This keeps the rows honest and avoids
  fake-zeros polluting averages.
- **Session IDs are never invented.** If the tool didn't give us one, we
  omit the field. (This rules out Vibe for v1 anyway.)
- **No `quota_*` fields in v1** — see the Quota section below. We
  deliberately make zero outbound calls to vendor APIs. Token totals
  from the transcript are the proxy we have.

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
forwarded into `event_original`. The emitter opens `transcript_path`,
reads the **last** assistant message (which carries the just-completed
turn's `usage` block), and copies its `input_tokens`,
`output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens` into the `tokens_turn_*` fields. The
`message.id` and `request_id` are also copied through as `message_id`
and `request_id` so ClickHouse can dedupe (compaction can cause the
same turn to appear in two JSONL files — every community tool runs
into this).

This is the same approach used by `ccusage`, `Claude-Code-Usage-Monitor`,
`ccflare`, etc. — there is no API call or CLI invocation needed for
token counts.

### Codex (OpenAI)

End-of-turn is enough. The installer sets in `~/.codex/config.toml`:

```toml
notify = ["claude-metrics-emit", "codex-notify"]
```

Codex invokes the `notify` script at end-of-turn with a JSON string as
the last argv, e.g.:

```json
{
  "type": "agent-turn-complete",
  "turn-id": "12345",
  "input-messages": ["Rename `foo` to `bar`."],
  "last-assistant-message": "Done.",
  "cwd": "/path/to/project",
  "client": "codex-tui"
}
```

Notes:

- The `notify` payload has **no session_id, no model, no token usage**.
  We pick those up from the active rollout JSONL at
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`cwd` and `turn-id`
  let us identify the right one — newest matching file wins).
- Token usage lives in rollout events with
  `payload.type == "token_count"`. `info.last_token_usage.*` gives the
  per-turn numbers we need (`input_tokens`, `cached_input_tokens`,
  `output_tokens`, `reasoning_output_tokens`).
- Codex also has a `[hooks]` block in `config.toml` exposing
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PermissionRequest`, `Stop`. v1 sticks to `notify` for simplicity;
  if we later want session boundaries / per-prompt events from Codex,
  we add them there — **no binary wrapping needed**.

If the user has an existing `notify = […]` line, the installer refuses to
overwrite it and prints a diff for manual merge. (Editing arbitrary TOML
arrays automatically is more risk than reward.)

### Vibe (Mistral)

**Skipped in v1.** Revisit when Vibe ships a hook system.

## Quota — dropped from v1 (computed server-side instead)

We explicitly do **not** call any Anthropic / OpenAI API to fetch quota.

Why: the only viable source for Claude's 5-hour / weekly subscription
limits is the undocumented `GET /api/oauth/usage` endpoint that the
`/usage` slash command hits internally. Calling that ourselves means
our shim shows up in Anthropic's server-side telemetry as a non-Claude
Code client (different call pattern, no real Claude Code request
context). We will not give them a signal that something other than
Claude Code is touching the account — the risk of an account flag or
TOS friction is not worth a quota gauge in a dashboard.

Locally, neither Claude Code nor Codex persists meaningful quota state:

- `~/.claude/policy-limits.json` → restriction flags only.
- `~/.claude/stats-cache.json` → local message/session counts; no
  subscription quota.
- `~/.codex/...` → no quota state at all.

So v1 emits **no `quota_*` fields**. If/when Anthropic ships a local
quota file or an official non-interactive command, we add it then.

Tokens-per-turn from the transcript are already an excellent proxy for
"how heavy is this session", and the ClickHouse side can compute
rolling windows from `SUM(tokens_turn_*)` over 5h / 7d if a quota-like
visualisation is needed.

### Confirmed by prior-art survey (May 2026)

Every open-source Claude-Code quota tool either (a) calls the same
account-unsafe OAuth endpoint or (b) does pure local JSONL bucketing.
There is no third option.

| Project | Approach | API calls? |
|---|---|---|
| `ccusage` (ryoppippi) | Sum JSONL per-turn tokens, bucket into 5h "blocks". | No |
| `Claude-Code-Usage-Monitor` (Maciek-roboblog) | Same; offers P90 self-calibration over last 192h instead of fixed budgets. | No |
| `phuryn/claude-usage`, `ccflare` | Same JSONL bucketing. | No |
| `usage-monitor-for-claude` (jens-duttke) | Calls `GET /api/oauth/usage`. | **Yes** — off-limits for us |

No project was found that consumes a server-mirrored local quota file —
because there isn't one. Hooks don't carry rate-limit fields either
(confirmed in `anthropics/claude-code#50518`: payloads have only
`session_id`, `transcript_path`, `cwd`, `permission_mode`).

**Caveat noted by ccusage maintainers**: per-turn JSONL `usage` blocks
can undercount what Anthropic actually bills (some sub-agent tool
calls aren't logged). Our numbers will run slightly low vs. the
official `/usage` panel — acceptable for trend analysis.

### Conclusion for our design

We already emit per-turn tokens with timestamps. The 5-hour-window
"how close are we to the quota" question is a ClickHouse query
(`SUM(tokens_turn_input+tokens_turn_output+...) WHERE timestamp >
now() - INTERVAL 5 HOUR GROUP BY user, host`). No client-side
bucketing, no plan-budget constants compiled into the shim, no extra
fields. The dashboard layer compares the rolling sum to a configurable
budget per user.

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
- Per-turn token values (Claude Code's native shape), named with the
  explicit `tokens_turn_*` prefix; ClickHouse aggregates with `SUM()`.
- No quota fields. No outbound calls to Anthropic / OpenAI APIs at
  all — strict invariant: never look like a non-vendor client to the
  vendor's servers.
- Subject: `<prefix>.<tool>.<event>.<host>.<user>`.
- Config: single `~/.config/claude-metrics/nats.conf` with `NATS_URL`,
  `NATS_SUBJECT_PREFIX`, `NATS_SEED` (inline seed), `CUSTOMER_TENANT`,
  `CUSTOMER_PROJECT`, `HOST_GROUP`. Missing file = opt-out.

## Resolved during shaping

- **nats CLI seed**: `--seed` takes the value inline (env var
  `NATS_SEED`). No tempfile or process substitution needed.
- **Claude Code local quota file**: doesn't exist. Use the OAuth
  endpoint `GET https://api.anthropic.com/api/oauth/usage` with the
  bearer from `~/.claude/.credentials.json`.
- **Codex `notify` payload**: kebab-case JSON in argv, fields
  `type, turn-id, input-messages, last-assistant-message, cwd, client`.
  No session_id, no model, no usage — those come from
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
  (`payload.type == "token_count"` → `info.last_token_usage.*`).
- **Token shape**: per-turn (Claude's native), fields are
  `tokens_turn_input`, `tokens_turn_output`, `tokens_turn_cache_read`,
  plus tool-specific `tokens_turn_cache_creation_claude` and
  `tokens_turn_reasoning_output_codex`. Tool-specific fields are
  omitted when the source tool doesn't produce them.
- **Dedupe**: emit `message_id` + `request_id` so ClickHouse can
  dedupe across compacted sessions (the `ccusage` gotcha).

## Open at implementation time

- Exact field names in the `/api/oauth/usage` response — captured against
  a live call when the formula is being coded.
- Whether to also wire Codex's `[hooks]` block for session boundaries
  (cheap, but adds installer complexity). Default: no, revisit after v1.
