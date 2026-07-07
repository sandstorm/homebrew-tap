# typed: false
# frozen_string_literal: true

class ClaudeMetrics < Formula
  desc "Claude Code usage metrics published to NATS via statusLine"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "0.5.0"

  # jq and nats are intentionally not depends_on — any homebrew/core or
  # cross-tap dep forces Homebrew to clone that tap, which fails on
  # machines where homebrew/core is not already tapped.
  # Install separately:
  #   brew install jq
  #   brew install nats-io/nats-tools/nats

  def install
    (buildpath/"claude-metrics-statusline").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-statusline
      #
      # Single-script implementation of Claude Code → NATS metrics, wired in
      # as the statusLine command. Reads the statusLine stdin JSON, builds a
      # flat payload, and fires it at NATS asynchronously. Prints an empty
      # status line. Never blocks Claude Code. Silent on failure unless
      # CLAUDE_METRICS_DEBUG=1.
      #
      # Opt out by removing ~/.config/claude-metrics/nats.conf.

      set -u

      DEBUG="${CLAUDE_METRICS_DEBUG:-0}"
      _log() { [ "$DEBUG" = "1" ] && echo "claude-metrics: $*" >&2; return 0; }
      _warn(){ echo "claude-metrics: $*" >&2; }

      # statusLine expects output on stdout — print empty line on any exit
      # until we've rendered the real status line below.
      trap 'echo ""' EXIT

      STDIN=$(cat)
      [ -n "$STDIN" ] || exit 0

      # --- Render the status line (printed via the EXIT trap) ---------------
      # We show only the "how full is it" row — no dir/branch/model row:
      #   ctx:N% tok:Nk +N/-N  │  5hr:N% reset H:M · 7d:N% reset H:M
      # Every percentage is USED/FULL: green (empty) → red (full).
      STATUS=""
      if command -v jq >/dev/null 2>&1; then
        # Force the C locale so numbers use "." (not "," under de_DE) and the
        # am/pm + weekday names rendered by date(1) come out in English.
        # Must be exported so the awk/date child processes inherit it.
        export LC_ALL=C
        _sl_col() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
        _sl_jv()  { printf '%s' "$STDIN" | jq -r "$1" 2>/dev/null; }

        # Color a percentage by how full it is: low=green, high=red.
        # Non-numeric input falls back to 0 so we never crash a render.
        _sl_pct() {
          _r=$(printf '%.0f' "$1" 2>/dev/null || echo 0)
          [ -n "$_r" ] || _r=0
          if   [ "$_r" -le 40 ]; then _sl_col 32 "$2"
          elif [ "$_r" -le 70 ]; then _sl_col 33 "$2"
          else                        _sl_col 31 "$2"; fi
        }

        _sl_tok() {
          if   [ "$1" -ge 1000000 ]; then awk "BEGIN{printf \"%.1fM\",$1/1000000}"
          elif [ "$1" -ge 1000 ];    then awk "BEGIN{printf \"%.1fk\",$1/1000}"
          else echo "$1"; fi
        }

        # "LABEL:N% reset TIME" — shows USED/FULL percentage, colored.
        _sl_limit() {
          _label="$1"; _used="$2"; _at="$3"; _datefmt="$4"
          { [ -z "$_used" ] || [ "$_used" = "null" ]; } && return 0
          _u=$(printf '%.0f' "$_used" 2>/dev/null || echo 0)
          [ -n "$_u" ] || _u=0
          _reset=""
          { [ -n "$_at" ] && [ "$_at" != "null" ]; } && \
            _reset=$(date -r "$_at" "+$_datefmt" 2>/dev/null | tr '[:upper:]' '[:lower:]')
          _cp=$(_sl_pct "$_u" "${_u}%")
          if [ -n "$_reset" ]; then
            printf '%s:%b %s' "$_label" "$_cp" "$(_sl_col 90 "reset $_reset")"
          else
            printf '%s:%b' "$_label" "$_cp"
          fi
        }

        _sl_ctx=$(_sl_jv '.context_window.used_percentage // empty')
        _sl_ti=$(_sl_jv '.context_window.total_input_tokens // 0' | tr -cd '0-9')
        _sl_to=$(_sl_jv '.context_window.total_output_tokens // 0' | tr -cd '0-9')
        _sl_total=$(( ${_sl_ti:-0} + ${_sl_to:-0} ))
        _sl_la=$(_sl_jv '.cost.total_lines_added // 0')
        _sl_lr=$(_sl_jv '.cost.total_lines_removed // 0')

        # Group 1: session usage
        _sl_usage=""
        _sl_add() { _sl_usage="${_sl_usage:+$_sl_usage  }$1"; }
        [ -n "$_sl_ctx" ]      && _sl_add "ctx:$(_sl_pct "$_sl_ctx" "${_sl_ctx}%")"
        [ "$_sl_total" -gt 0 ] && _sl_add "$(_sl_col 36 "tok:$(_sl_tok "$_sl_total")")"
        { [ "$_sl_la" != "0" ] || [ "$_sl_lr" != "0" ]; } && \
          _sl_add "$(_sl_col 32 "+$_sl_la")/$(_sl_col 31 "-$_sl_lr")"

        # Group 2: rate-limit budgets
        _sl_limits=""
        _sl_addl() { _sl_limits="${_sl_limits:+$_sl_limits  }$1"; }
        _sl_five=$(_sl_limit "5hr" \
          "$(_sl_jv '.rate_limits.five_hour.used_percentage // empty')" \
          "$(_sl_jv '.rate_limits.five_hour.resets_at // empty')" "%H:%M")
        _sl_seven=$(_sl_limit "7d" \
          "$(_sl_jv '.rate_limits.seven_day.used_percentage // empty')" \
          "$(_sl_jv '.rate_limits.seven_day.resets_at // empty')" "%a %H:%M")
        [ -n "$_sl_five" ]  && _sl_addl "$_sl_five"
        [ -n "$_sl_seven" ] && _sl_addl "$_sl_seven"

        if [ -n "$_sl_usage" ] && [ -n "$_sl_limits" ]; then
          STATUS="$_sl_usage  $(_sl_col 90 "│")  $_sl_limits"
        elif [ -n "$_sl_usage" ]; then
          STATUS="$_sl_usage"
        elif [ -n "$_sl_limits" ]; then
          STATUS="$_sl_limits"
        fi
      fi

      # --- Optional claude-carbon CO2 row ----------------------------------
      # If the (optional) claude-carbon add-on is installed, render its CO2
      # line below ours. Best-effort: any failure leaves CARBON_ROW empty and
      # never breaks the metrics render. Location defaults to
      # ~/.claude/claude-carbon; override with the CLAUDE_CARBON_DIR env var.
      CARBON_ROW=""
      CARBON_DIR="${CLAUDE_CARBON_DIR:-$HOME/.claude/claude-carbon}"
      case "$CARBON_DIR" in "~/"*) CARBON_DIR="${HOME}/${CARBON_DIR#~/}" ;; esac
      if [ -x "$CARBON_DIR/scripts/statusline.sh" ]; then
        CARBON_ROW=$(printf '%s' "$STDIN" | bash "$CARBON_DIR/scripts/statusline.sh" 2>/dev/null)
      fi

      # From here on, any exit prints the rendered status line(s): metrics row
      # first, optional carbon row below.
      trap '{ printf "%b\n" "$STATUS"; [ -n "$CARBON_ROW" ] && printf "%s\n" "$CARBON_ROW"; }' EXIT

      CONF="${HOME}/.config/claude-metrics/nats.conf"
      [ -r "$CONF" ] || { _log "no config at $CONF (opt-out)"; exit 0; }

      NATS_URL=""
      NATS_SUBJECT_PREFIX="logs.default.claudemetrics"
      NATS_NKEY_FILE="${HOME}/.config/claude-metrics/submission-key.nkey"
      CUSTOMER_TENANT=""
      CUSTOMER_PROJECT=""
      HOST_GROUP=""

      # shellcheck disable=SC1090
      . "$CONF"

      case "$NATS_NKEY_FILE" in
        "~/"*) NATS_NKEY_FILE="${HOME}/${NATS_NKEY_FILE#~/}" ;;
      esac

      # Dep + config checks — always loud, since silence here is what made
      # debugging horrible before.
      [ -n "$NATS_URL" ]                || { _warn "NATS_URL unset in $CONF";      exit 0; }
      command -v jq   >/dev/null 2>&1   || { _warn "jq not found — brew install jq"; exit 0; }
      command -v nats >/dev/null 2>&1   || { _warn "nats not found — brew install nats-io/nats-tools/nats"; exit 0; }
      [ -r "$NATS_NKEY_FILE" ]          || { _warn "nkey file unreadable: $NATS_NKEY_FILE"; exit 0; }

      _perm=$(stat -f '%Lp' "$NATS_NKEY_FILE" 2>/dev/null || stat -c '%a' "$NATS_NKEY_FILE" 2>/dev/null || echo "")
      [ "$_perm" = "600" ] || { _warn "nkey must be mode 0600 (got '$_perm')"; exit 0; }

      # Debounce — at most one emission per 60 s. statusLine fires on every
      # render which can be many per second.
      STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-metrics"
      STATE="$STATE_DIR/statusline-last"
      mkdir -p "$STATE_DIR" 2>/dev/null || true

      NOW=$(date +%s)
      LAST_TIME=0
      if [ -r "$STATE" ]; then
        # Take the first line and keep only digits. This tolerates a corrupt
        # or legacy (KEY=value) state file — otherwise a non-numeric value
        # crashes the arithmetic below under `set -u`, which exits non-zero
        # and makes Claude Code suppress the whole status line. A bad file
        # would also stay bad forever, since we never reach the rewrite.
        LAST_TIME=$(head -n1 "$STATE" 2>/dev/null | tr -cd '0-9' | cut -c1-18)
        [ -n "$LAST_TIME" ] || LAST_TIME=0
      fi
      ELAPSED=$(( NOW - LAST_TIME ))
      if [ "$ELAPSED" -lt 60 ]; then
        _log "debounced (last emit ${ELAPSED}s ago)"
        exit 0
      fi
      echo "$NOW" > "$STATE" 2>/dev/null || true

      USER_NAME="${USER:-$(id -un 2>/dev/null || echo unknown)}"
      HOST_NAME="$(hostname -s 2>/dev/null || echo unknown)"

      # UTC timestamp with microseconds, space separator (ClickHouse DateTime64(6))
      TS=$(perl -MTime::HiRes=gettimeofday -e '
        my ($s,$us) = gettimeofday();
        my @g = gmtime($s);
        printf("%04d-%02d-%02d %02d:%02d:%02d.%06d\n",
               $g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0],$us);
      ' 2>/dev/null) || TS="$(date -u +'%Y-%m-%d %H:%M:%S.000000')"

      # Hash cwd so we can group by project without leaking paths.
      CWD=$(printf '%s' "$STDIN" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null || echo "")
      [ -n "$CWD" ] || CWD="$PWD"
      CWD_HASH=$(printf '%s' "$CWD" | shasum -a 256 2>/dev/null | awk '{print $1}')

      SUBJECT="${NATS_SUBJECT_PREFIX}.claude.quota_sample.${HOST_NAME}.${USER_NAME}"

      PAYLOAD=$(printf '%s' "$STDIN" | jq -c \
        --arg customer_tenant   "$CUSTOMER_TENANT" \
        --arg customer_project  "$CUSTOMER_PROJECT" \
        --arg host_group        "$HOST_GROUP" \
        --arg host_name         "$HOST_NAME" \
        --arg timestamp         "$TS" \
        --arg user              "$USER_NAME" \
        --arg cwd_hash          "$CWD_HASH" \
        '
        {
          # Standard envelope (ClickHouse sandstorm_monitoring_v2_db.full_logs)
          customer_tenant:  $customer_tenant,
          customer_project: $customer_project,
          host_group:       $host_group,
          host_name:        $host_name,
          event_module:     "agent-metrics",
          event_dataset:    "agent-metrics.claude.quota_sample",
          timestamp:        $timestamp,
          level:            "info",
          tool:             "claude",
          event:            "quota_sample",
          user:             $user,
          cwd_hash:         $cwd_hash,

          # Identity / model
          tool_version:  .version,
          session_id:    .session_id,
          session_name:  .session_name,
          model:         (.model.id // (.model | strings)),

          # Rate-limit buckets (Claude Code v2.1.80+)
          quota_five_hour_pct_used:         .rate_limits.five_hour.used_percentage,
          quota_five_hour_resets_at:        .rate_limits.five_hour.resets_at,
          quota_seven_day_pct_used:         .rate_limits.seven_day.used_percentage,
          quota_seven_day_resets_at:        .rate_limits.seven_day.resets_at,
          quota_seven_day_opus_pct_used:    .rate_limits.seven_day_opus.used_percentage,
          quota_seven_day_opus_resets_at:   .rate_limits.seven_day_opus.resets_at,
          quota_seven_day_sonnet_pct_used:  .rate_limits.seven_day_sonnet.used_percentage,
          quota_seven_day_sonnet_resets_at: .rate_limits.seven_day_sonnet.resets_at,

          # Cumulative session cost & activity
          session_cost_usd:        .cost.total_cost_usd,
          session_duration_ms:     .cost.total_duration_ms,
          session_api_duration_ms: .cost.total_api_duration_ms,
          session_lines_added:     .cost.total_lines_added,
          session_lines_removed:   .cost.total_lines_removed,

          # Context window pressure
          context_window_pct_used:     .context_window.used_percentage,
          context_window_pct_free:     .context_window.remaining_percentage,
          context_window_size:         .context_window.context_window_size,
          context_window_tokens_total: .context_window.total_input_tokens,

          # Last-turn token usage (lives in context_window.current_usage)
          tokens_turn_input:                 .context_window.current_usage.input_tokens,
          tokens_turn_output:                .context_window.current_usage.output_tokens,
          tokens_turn_cache_read:            .context_window.current_usage.cache_read_input_tokens,
          tokens_turn_cache_creation_claude: .context_window.current_usage.cache_creation_input_tokens,

          # Session metadata
          effort_level:        .effort.level,
          output_style:        .output_style.name,
          fast_mode:           (if .fast_mode           != null then .fast_mode           else null end),
          thinking_enabled:    (if .thinking.enabled    != null then .thinking.enabled    else null end),
          exceeds_200k_tokens: (if .exceeds_200k_tokens != null then .exceeds_200k_tokens else null end)
        }
        | with_entries(select(.value != null))
        ' 2>/dev/null)

      [ -n "$PAYLOAD" ] || { _warn "failed to build payload"; exit 0; }

      _log "subject=$SUBJECT"
      _log "payload=$PAYLOAD"

      # Fire-and-forget. macOS has no timeout(1); fall back gracefully.
      _publish() {
        if command -v gtimeout >/dev/null 2>&1; then
          gtimeout 2s nats --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
        elif command -v timeout >/dev/null 2>&1; then
          timeout  2s nats --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
        else
          nats        --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
        fi
      }

      if [ "$DEBUG" = "1" ]; then
        ( _publish >&2 & )
      else
        ( _publish >/dev/null 2>&1 & )
      fi
      disown 2>/dev/null || true

      exit 0
    BASH

    bin.install "claude-metrics-statusline"

    (buildpath/"claude-metrics-install").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-install
      #
      # Wires claude-metrics-statusline into ~/.claude/settings.json.
      # Refuses to overwrite a pre-existing different .statusLine.
      #
      # Also migrates away from the old (<=0.1.0) hook-based design: that
      # version's installer wrote SessionStart/UserPromptSubmit/Stop/
      # SessionEnd hooks calling `claude-metrics-emit`, a binary this
      # version no longer ships. Left in place those hooks fail on every
      # event with "claude-metrics-emit: command not found", so we strip
      # them here.
      #
      # Optional: `--carbon` also enables the claude-carbon CO2 add-on
      # (clone-at-pinned-commit + SQLite history + a CO2 row below the metrics
      # row). Without the flag this installs metrics only — no carbon.

      set -euo pipefail

      MANAGED="sandstorm-claude-metrics"
      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      OURS="claude-metrics-statusline"

      # Optional claude-carbon add-on — off unless --carbon is passed.
      WANT_CARBON=0
      case "${1:-}" in
        --carbon|carbon) WANT_CARBON=1 ;;
        "")              : ;;
        *) echo "usage: claude-metrics-install [--carbon]" >&2; exit 2 ;;
      esac
      CARBON_PIN="5e4551ada88ead9b2ec443fa74a36180da049020"
      CARBON_REPO="https://github.com/gwittebolle/claude-carbon.git"
      CARBON_MANAGED="sandstorm-claude-metrics-carbon"

      command -v jq >/dev/null 2>&1 || { echo "❌ jq required — brew install jq" >&2; exit 1; }

      mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
      [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

      EXISTING=$(jq -r '.statusLine.command // ""' "$CLAUDE_SETTINGS" 2>/dev/null || echo "")
      if [ -n "$EXISTING" ] && [ "$EXISTING" != "$OURS" ]; then
        echo "⚠️  $CLAUDE_SETTINGS already has a different .statusLine:" >&2
        echo "       $EXISTING" >&2
        echo "    Refusing to overwrite. If you want metrics, change it manually to:" >&2
        echo "       $OURS" >&2
        exit 1
      fi

      # Strip stale claude-metrics-emit hooks, then wire in our statusLine.
      # An entry is ours if it carries the managed tag OR any of its inner
      # hooks invokes claude-metrics-emit (covers hand-copied duplicates
      # that lost the _managed_by tag).
      tmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
      jq --arg c "$OURS" --arg m "$MANAGED" '
        def is_ours:
          ((.hooks[0]._managed_by // "") == $m)
          or ((.hooks // []) | any((.command // "") | startswith("claude-metrics-emit")));
        def strip(arr): (arr // []) | map(select(is_ours | not));
        (if (.hooks | type) == "object" then
          .hooks.SessionStart     = strip(.hooks.SessionStart)
          | .hooks.UserPromptSubmit = strip(.hooks.UserPromptSubmit)
          | .hooks.Stop             = strip(.hooks.Stop)
          | .hooks.SessionEnd       = strip(.hooks.SessionEnd)
          | .hooks |= with_entries(select((.value | length) > 0))
          | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end)
        | . + {statusLine: {type:"command", command:$c}}
      ' "$CLAUDE_SETTINGS" > "$tmp"
      mv "$tmp" "$CLAUDE_SETTINGS"
      echo "✅ Wired $OURS into $CLAUDE_SETTINGS (and removed any stale claude-metrics-emit hooks)"

      cat <<EOM

      Next:
        1. Install runtime deps (if not done):
             brew install jq
             brew install nats-io/nats-tools/nats
        2. Create ~/.config/claude-metrics/nats.conf:
             mkdir -p ~/.config/claude-metrics
             cp $(brew --prefix)/share/claude-metrics/nats.conf.example ~/.config/claude-metrics/nats.conf
             # …edit it with your real NATS_URL and CUSTOMER_* tags
        3. Drop your nkey seed (mode 0600):
             install -m 600 /dev/stdin ~/.config/claude-metrics/submission-key.nkey <<<'SU...'
        4. Verify:
             claude-metrics-status

      EOM

      # --- Optional claude-carbon add-on (--carbon) -------------------------
      if [ "$WANT_CARBON" = "1" ]; then
        echo ""
        echo "── claude-carbon add-on ──────────────────────────────────────"
        for c in git sqlite3; do
          command -v "$c" >/dev/null 2>&1 || { echo "❌ $c required for --carbon — brew install $c" >&2; exit 1; }
        done

        # Default location ~/.claude/claude-carbon (also where carbon keeps its
        # SQLite DB, so repo + DB share one dir); override with CLAUDE_CARBON_DIR.
        CARBON_DIR="${CLAUDE_CARBON_DIR:-$HOME/.claude/claude-carbon}"
        case "$CARBON_DIR" in "~/"*) CARBON_DIR="${HOME}/${CARBON_DIR#~/}" ;; esac

        # Clone fresh / init-in-place (dir already exists, e.g. a prior carbon
        # DB) / fetch (repo already here), then HARD-PIN to the fixed commit.
        # Pinning is the supply-chain guard — we never track a moving branch.
        if [ -d "$CARBON_DIR/.git" ]; then
          echo "→ Fetching claude-carbon in $CARBON_DIR ..."
          git -C "$CARBON_DIR" fetch --quiet --tags origin
        elif [ -d "$CARBON_DIR" ] && [ -n "$(ls -A "$CARBON_DIR" 2>/dev/null)" ]; then
          echo "→ Initialising claude-carbon repo in existing $CARBON_DIR ..."
          git -C "$CARBON_DIR" init --quiet
          git -C "$CARBON_DIR" remote add origin "$CARBON_REPO" 2>/dev/null \
            || git -C "$CARBON_DIR" remote set-url origin "$CARBON_REPO"
          git -C "$CARBON_DIR" fetch --quiet --tags origin
        else
          echo "→ Cloning claude-carbon to $CARBON_DIR ..."
          mkdir -p "$(dirname "$CARBON_DIR")"
          git clone --quiet "$CARBON_REPO" "$CARBON_DIR"
        fi
        git -C "$CARBON_DIR" checkout --quiet "$CARBON_PIN"
        HEAD="$(git -C "$CARBON_DIR" rev-parse HEAD)"
        [ "$HEAD" = "$CARBON_PIN" ] || { echo "❌ carbon commit pin mismatch: got $HEAD, want $CARBON_PIN" >&2; exit 1; }
        echo "✅ claude-carbon pinned at $CARBON_PIN ($CARBON_DIR)"

        # DB init + history backfill. The installer flag makes setup.sh skip its
        # own settings wiring — the metrics statusLine already renders the CO2 row.
        CLAUDE_CARBON_INSTALLER=1 bash "$CARBON_DIR/scripts/setup.sh"

        # Add carbon's Stop (persist) + SessionStart (safety-rescan) hooks,
        # tagged so claude-metrics-uninstall can find and remove them.
        PERSIST="${CARBON_DIR}/scripts/persist-session.sh"
        RESCAN="${CARBON_DIR}/scripts/safety-rescan.sh"
        ctmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
        jq --arg persist "$PERSIST" --arg rescan "$RESCAN" --arg m "$CARBON_MANAGED" '
          def has_cmd(arr; c): (arr // []) | map(.hooks // []) | flatten | any(.command == c);
          .hooks = (.hooks // {})
          | (if has_cmd(.hooks.Stop; $persist) then . else
              .hooks.Stop = ((.hooks.Stop // []) + [{_managed_by:$m, matcher:"", hooks:[{type:"command", command:$persist}]}]) end)
          | (if has_cmd(.hooks.SessionStart; $rescan) then . else
              .hooks.SessionStart = ((.hooks.SessionStart // []) + [{_managed_by:$m, matcher:"", hooks:[{type:"command", command:$rescan}]}]) end)
        ' "$CLAUDE_SETTINGS" > "$ctmp"
        mv "$ctmp" "$CLAUDE_SETTINGS"
        echo "✅ Added carbon Stop/SessionStart hooks"

        # Slash-command symlinks (skip if already present).
        CMDS="${HOME}/.claude/commands"; mkdir -p "$CMDS"
        for s in carbon-report carbon-card carbon-update; do
          src="${CARBON_DIR}/skills/${s}/SKILL.md"; lnk="${CMDS}/${s}.md"
          { [ -e "$lnk" ] || [ -L "$lnk" ]; } || ln -s "$src" "$lnk"
        done
        echo "✅ carbon slash commands: /carbon-report /carbon-card /carbon-update"
        echo "   Restart Claude Code — a CO2 row now renders below the metrics row."
      fi
    BASH

    bin.install "claude-metrics-install"

    (buildpath/"claude-metrics-uninstall").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-uninstall
      #
      # Removes the statusLine entry from settings.json if it points at us,
      # and strips any stale claude-metrics-emit lifecycle hooks left over
      # from the old (<=0.1.0) hook-based design. If the optional claude-carbon
      # add-on was enabled, its hooks + slash commands are removed too — this
      # always tears down everything we (or --carbon) installed. The cloned
      # repo and SQLite history stay on disk; remove them by hand if wanted.

      set -euo pipefail

      MANAGED="sandstorm-claude-metrics"
      CARBON_MANAGED="sandstorm-claude-metrics-carbon"
      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      OURS="claude-metrics-statusline"

      command -v jq >/dev/null 2>&1 || { echo "❌ jq required — brew install jq" >&2; exit 1; }

      [ -f "$CLAUDE_SETTINGS" ] || { echo "ℹ️  $CLAUDE_SETTINGS not found — nothing to do."; exit 0; }

      tmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
      jq --arg o "$OURS" --arg m "$MANAGED" --arg cm "$CARBON_MANAGED" '
        # An entry is ours if it carries either managed tag, invokes the old
        # claude-metrics-emit binary, or (carbon) references claude-carbon.
        def is_ours:
          ((.hooks[0]._managed_by // "") == $m)
          or ((.hooks[0]._managed_by // "") == $cm)
          or ((.hooks // []) | any((.command // "") | (startswith("claude-metrics-emit") or test("claude-carbon"))));
        def strip(arr): (arr // []) | map(select(is_ours | not));
        (if (.statusLine.command // "") == $o then del(.statusLine) else . end)
        | (if (.hooks | type) == "object" then
            .hooks.SessionStart     = strip(.hooks.SessionStart)
            | .hooks.UserPromptSubmit = strip(.hooks.UserPromptSubmit)
            | .hooks.Stop             = strip(.hooks.Stop)
            | .hooks.SessionEnd       = strip(.hooks.SessionEnd)
            | .hooks |= with_entries(select((.value | length) > 0))
            | (if (.hooks | length) == 0 then del(.hooks) else . end)
          else . end)
      ' "$CLAUDE_SETTINGS" > "$tmp"
      mv "$tmp" "$CLAUDE_SETTINGS"

      # Remove carbon slash-command symlinks too (no-op if they were never added).
      for s in carbon-report carbon-card carbon-update; do
        lnk="${HOME}/.claude/commands/${s}.md"
        [ -L "$lnk" ] && rm -f "$lnk"
      done

      echo "✅ Removed claude-metrics statusLine + stale hooks (and any claude-carbon hooks/commands) from $CLAUDE_SETTINGS"
      echo "   claude-carbon repo + SQLite history (if any) left on disk: ~/.claude/claude-carbon"
    BASH

    bin.install "claude-metrics-uninstall"

    (buildpath/"claude-metrics-status").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-status — pass/fail diagnostic summary

      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      CONF="${HOME}/.config/claude-metrics/nats.conf"
      NATS_NKEY_FILE="${HOME}/.config/claude-metrics/submission-key.nkey"

      ok()   { printf "  ✅  %s\n" "$*"; }
      fail() { printf "  ❌  %s\n" "$*"; FAILED=1; }
      warn() { printf "  ⚠️   %s\n" "$*"; }
      FAILED=0

      echo ""
      echo "── Runtime dependencies ──────────────────────────────────────"
      command -v jq   >/dev/null 2>&1 && ok "jq found"   || fail "jq not found (brew install jq)"
      command -v nats >/dev/null 2>&1 && ok "nats found" || fail "nats not found (brew install nats-io/nats-tools/nats)"

      echo ""
      echo "── Config ────────────────────────────────────────────────────"
      if [ -r "$CONF" ]; then
        ok "nats.conf present ($CONF)"
        NATS_URL=""
        # shellcheck disable=SC1090
        . "$CONF" 2>/dev/null || true
        [ -n "$NATS_URL" ] && ok "NATS_URL set ($NATS_URL)" || fail "NATS_URL not set"

        case "${NATS_NKEY_FILE:-}" in
          "~/"*) NATS_NKEY_FILE="${HOME}/${NATS_NKEY_FILE#~/}" ;;
        esac
        NATS_NKEY_FILE="${NATS_NKEY_FILE:-$HOME/.config/claude-metrics/submission-key.nkey}"

        if [ -r "$NATS_NKEY_FILE" ]; then
          _perm=$(stat -f '%Lp' "$NATS_NKEY_FILE" 2>/dev/null || stat -c '%a' "$NATS_NKEY_FILE" 2>/dev/null || echo "?")
          [ "$_perm" = "600" ] && ok "nkey present and 0600 ($NATS_NKEY_FILE)" \
                              || fail "nkey mode is $_perm (chmod 600 $NATS_NKEY_FILE)"
        else
          fail "nkey missing or unreadable ($NATS_NKEY_FILE)"
        fi
      else
        warn "nats.conf not found — emitter is in opt-out mode (silent)"
      fi

      echo ""
      echo "── Claude Code statusLine ($CLAUDE_SETTINGS) ────────────────"
      if [ ! -f "$CLAUDE_SETTINGS" ]; then
        fail "settings.json not found — run: claude-metrics-install"
      elif ! command -v jq >/dev/null 2>&1; then
        warn "jq unavailable — cannot inspect settings"
      else
        cmd=$(jq -r '.statusLine.command // ""' "$CLAUDE_SETTINGS" 2>/dev/null || echo "")
        case "$cmd" in
          claude-metrics-statusline) ok "statusLine wired" ;;
          "")  fail "statusLine not set — run: claude-metrics-install" ;;
          *)   fail "statusLine points elsewhere: '$cmd' (run claude-metrics-install to override)" ;;
        esac
      fi

      echo ""
      echo "── claude-carbon add-on (optional) ───────────────────────────"
      CARBON_PIN="5e4551ada88ead9b2ec443fa74a36180da049020"
      CARBON_DIR="${CLAUDE_CARBON_DIR:-$HOME/.claude/claude-carbon}"
      case "$CARBON_DIR" in "~/"*) CARBON_DIR="${HOME}/${CARBON_DIR#~/}" ;; esac
      if [ -d "$CARBON_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        HEAD="$(git -C "$CARBON_DIR" rev-parse HEAD 2>/dev/null || echo "?")"
        if [ "$HEAD" = "$CARBON_PIN" ]; then
          ok "claude-carbon present and pinned ($CARBON_DIR)"
        else
          warn "claude-carbon present but NOT at pinned commit (got ${HEAD:0:12}, want ${CARBON_PIN:0:12}) — run claude-metrics-install --carbon"
        fi
      else
        warn "claude-carbon not installed (optional) — run claude-metrics-install --carbon to add CO2 tracking"
      fi

      echo ""
      if [ "$FAILED" -eq 0 ]; then
        echo "All checks passed."
      else
        echo "Some checks failed — see above."
      fi
      echo ""
      exit "$FAILED"
    BASH

    bin.install "claude-metrics-status"

    (buildpath/"nats.conf.example").write <<~'CONF'
      # ~/.config/claude-metrics/nats.conf — sourced as shell variables
      #
      # Required:
      NATS_URL=tls://nats.example:4222
      NATS_NKEY_FILE=~/.config/claude-metrics/submission-key.nkey

      # Optional:
      NATS_SUBJECT_PREFIX=logs.default.claudemetrics

      # Tagging — emitted on every event so the central ClickHouse table
      # (sandstorm_monitoring_v2_db.full_logs) can slice by tenant/project/group.
      CUSTOMER_TENANT=sandstorm
      CUSTOMER_PROJECT=sandstorm.ai-metrics
      HOST_GROUP=laptops
    CONF

    (buildpath/"USAGE.md").write <<~'MD'
      # claude-metrics

      Claude Code usage metrics → NATS, via the statusLine hook. Captures
      per-render snapshots of:

      - Rate-limit buckets (5h, 7d, 7d-opus, 7d-sonnet) — used % + reset time
      - Cumulative session cost (USD), duration, lines added/removed
      - Context window pressure (% used, total tokens)
      - Last-turn token usage (input, output, cache read/creation)
      - Session metadata (model, effort, thinking enabled, fast mode)

      Debounced to one emission per 60 s.

      ## Install

          brew install jq
          brew install nats-io/nats-tools/nats
          brew install sandstorm/tap/claude-metrics
          claude-metrics-install

      ## Configure

          mkdir -p ~/.config/claude-metrics
          cp $(brew --prefix)/share/claude-metrics/nats.conf.example \
             ~/.config/claude-metrics/nats.conf
          # edit nats.conf
          install -m 600 /dev/stdin ~/.config/claude-metrics/submission-key.nkey <<<'SU...'

      ## Verify

          claude-metrics-status

      ## Opt out

      Remove `~/.config/claude-metrics/nats.conf` — the statusLine exits
      silently with no config.

      ## Optional: CO2 tracking (claude-carbon add-on)

      Installs [claude-carbon](https://github.com/gwittebolle/claude-carbon)
      pinned to a fixed commit and runs it *alongside* claude-metrics: the
      metrics row on top, a claude-carbon CO2 row below. It's a flag on the
      normal installer — no extra commands.

          brew install sqlite3 git    # extra deps carbon needs
          claude-metrics-install --carbon

      - Pinned to a known-good commit (supply-chain safety); re-run any time.
      - Cloned into `~/.claude/claude-carbon` (shared with carbon's SQLite DB);
        override via the `CLAUDE_CARBON_DIR` env var.
      - Adds carbon's Stop / SessionStart hooks + `/carbon-report`,
        `/carbon-card`, `/carbon-update` slash commands.
      - The CO2 row is rendered by `claude-metrics-statusline` itself when the
        add-on is present — the status line stays a single command.
      - `claude-metrics-uninstall` removes carbon too (keeps your history DB).
    MD

    (share/"claude-metrics").install "nats.conf.example", "USAGE.md"
  end

  def caveats
    <<~EOS
      Required runtime deps (not auto-installed — any homebrew/core or
      cross-tap dep forces tap-cloning which fails on machines where
      homebrew/core is not already tapped):
        brew install jq
        brew install nats-io/nats-tools/nats

      To wire it in:
        1. claude-metrics-install
        2. mkdir -p ~/.config/claude-metrics
           cp #{share}/claude-metrics/nats.conf.example ~/.config/claude-metrics/nats.conf
           # edit nats.conf, then drop your nkey seed (mode 0600):
           chmod 600 ~/.config/claude-metrics/submission-key.nkey
        3. claude-metrics-status

      Opt out by removing ~/.config/claude-metrics/nats.conf.

      Optional CO2 tracking (claude-carbon add-on):
        Also needs sqlite3 + git (brew install sqlite3 git), then:
          claude-metrics-install --carbon
        Clones claude-carbon pinned to a fixed commit into
        ~/.claude/claude-carbon, runs its setup, and renders its CO2 row
        *below* the metrics status line. Location override: CLAUDE_CARBON_DIR
        env var.
        Remove with: claude-metrics-uninstall (tears down carbon too)
    EOS
  end

  test do
    assert_predicate bin/"claude-metrics-statusline", :executable?
    assert_predicate bin/"claude-metrics-install",    :executable?
    assert_predicate bin/"claude-metrics-uninstall",  :executable?
    assert_predicate bin/"claude-metrics-status",     :executable?

    # No config and no carbon add-on → silent exit, status line is just an
    # empty newline. (The optional carbon CO2 row stays absent unless
    # ~/.claude/claude-carbon/scripts/statusline.sh exists.)
    ENV["HOME"] = testpath.to_s
    out = shell_output("echo '{}' | #{bin}/claude-metrics-statusline")
    assert_equal "\n", out
  end
end
