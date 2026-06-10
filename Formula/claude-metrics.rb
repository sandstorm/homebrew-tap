# typed: false
# frozen_string_literal: true

class ClaudeMetrics < Formula
  desc "Claude Code usage metrics published to NATS via statusLine"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "0.2.0"

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

      # statusLine expects output on stdout — print empty line on any exit.
      trap 'echo ""' EXIT

      STDIN=$(cat)
      [ -n "$STDIN" ] || exit 0

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
      [ -r "$STATE" ] && LAST_TIME=$(cat "$STATE" 2>/dev/null || echo 0)
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

      set -euo pipefail

      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      OURS="claude-metrics-statusline"

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

      tmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
      jq --arg c "$OURS" '. + {statusLine: {type:"command", command:$c}}' "$CLAUDE_SETTINGS" > "$tmp"
      mv "$tmp" "$CLAUDE_SETTINGS"
      echo "✅ Wired $OURS into $CLAUDE_SETTINGS"

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
    BASH

    bin.install "claude-metrics-install"

    (buildpath/"claude-metrics-uninstall").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-uninstall
      #
      # Removes the statusLine entry from settings.json if it points at us.

      set -euo pipefail

      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      OURS="claude-metrics-statusline"

      command -v jq >/dev/null 2>&1 || { echo "❌ jq required — brew install jq" >&2; exit 1; }

      [ -f "$CLAUDE_SETTINGS" ] || { echo "ℹ️  $CLAUDE_SETTINGS not found — nothing to do."; exit 0; }

      EXISTING=$(jq -r '.statusLine.command // ""' "$CLAUDE_SETTINGS" 2>/dev/null || echo "")
      if [ "$EXISTING" != "$OURS" ]; then
        echo "ℹ️  .statusLine is not claude-metrics (it's '$EXISTING') — nothing to do."
        exit 0
      fi

      tmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
      jq 'del(.statusLine)' "$CLAUDE_SETTINGS" > "$tmp"
      mv "$tmp" "$CLAUDE_SETTINGS"
      echo "✅ Removed statusLine from $CLAUDE_SETTINGS"
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
    EOS
  end

  test do
    assert_predicate bin/"claude-metrics-statusline", :executable?
    assert_predicate bin/"claude-metrics-install",    :executable?
    assert_predicate bin/"claude-metrics-uninstall",  :executable?
    assert_predicate bin/"claude-metrics-status",     :executable?

    # No config → silent exit, status line is just an empty newline.
    ENV["HOME"] = testpath.to_s
    out = shell_output("echo '{}' | #{bin}/claude-metrics-statusline")
    assert_equal "\n", out
  end
end
