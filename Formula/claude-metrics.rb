# typed: false
# frozen_string_literal: true

class ClaudeMetrics < Formula
  desc "Hook-driven usage metrics for Claude Code & Codex, published to NATS"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "0.1.0"

  # Both jq and nats are intentionally not listed as depends_on — any formula
  # in homebrew/core (e.g. jq) forces Homebrew to clone that tap, which fails
  # on machines where homebrew/core is not already tapped.
  # Install them separately:
  #   brew install jq
  #   brew install nats-io/nats-tools/nats

  def install
    (buildpath/"claude-metrics-emit").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-emit <event> [json-arg]
      #
      # Events: session_start | prompt | stop | session_end
      #         | quota_wall | quota_sample | api_error
      #         | codex-notify
      #
      # Reads the hook payload from stdin (Claude Code) or argv[2] (Codex notify).
      # Builds a flat JSON message and fires it at NATS, fully async.
      # Never blocks the caller. Silent on any failure unless CLAUDE_METRICS_DEBUG=1.

      set -u

      DEBUG="${CLAUDE_METRICS_DEBUG:-0}"
      _log() { [ "$DEBUG" = "1" ] && echo "claude-metrics-emit: $*" >&2; return 0; }
      _bail() { _log "$*"; exit 0; }

      EVENT="${1:-}"
      [ -n "$EVENT" ] || _bail "no event arg"

      CONF="${HOME}/.config/claude-metrics/nats.conf"
      [ -r "$CONF" ] || _bail "no config at $CONF (opt-out)"

      NATS_URL=""
      NATS_SUBJECT_PREFIX="logs.default.claudemetrics"
      NATS_NKEY_FILE="${HOME}/.config/claude-metrics/submission-key.nkey"
      CUSTOMER_TENANT=""
      CUSTOMER_PROJECT=""
      HOST_GROUP=""

      # shellcheck disable=SC1090
      . "$CONF"

      # Expand leading ~ in NATS_NKEY_FILE
      case "$NATS_NKEY_FILE" in
        "~/"*) NATS_NKEY_FILE="${HOME}/${NATS_NKEY_FILE#~/}" ;;
      esac

      [ -n "$NATS_URL" ] || _bail "NATS_URL unset"
      command -v jq   >/dev/null 2>&1 || _bail "jq not found — run: brew install jq"
      command -v nats >/dev/null 2>&1 || _bail "nats CLI not found — run: brew install nats-io/nats-tools/nats"
      [ -r "$NATS_NKEY_FILE" ] || _bail "nkey file unreadable: $NATS_NKEY_FILE"

      # Require 0600 on the seed file — anything looser is a misconfig.
      _perm=$(stat -f '%Lp' "$NATS_NKEY_FILE" 2>/dev/null || stat -c '%a' "$NATS_NKEY_FILE" 2>/dev/null || echo "")
      [ "$_perm" = "600" ] || _bail "nkey file must be mode 0600 (got '$_perm')"

      # ---------------------------------------------------------------------------
      # Read payload
      # ---------------------------------------------------------------------------
      case "$EVENT" in
        codex-notify)
          TOOL="codex"
          # Codex hands us the JSON as the last argv
          RAW_PAYLOAD="${2:-}"
          # Re-map event name: codex-notify -> stop (semantic end-of-turn)
          EVENT="stop"
          ;;
        *)
          TOOL="claude"
          RAW_PAYLOAD="$(cat)"
          ;;
      esac

      [ -n "$RAW_PAYLOAD" ] || RAW_PAYLOAD="{}"

      USER_NAME="${USER:-$(id -un 2>/dev/null || echo unknown)}"
      HOST_NAME="$(hostname -s 2>/dev/null || echo unknown)"

      # ISO-ish UTC timestamp with microseconds + space separator
      TS=$(perl -MTime::HiRes=gettimeofday -e '
        my ($s,$us) = gettimeofday();
        my @g = gmtime($s);
        printf("%04d-%02d-%02d %02d:%02d:%02d.%06d\n",
               $g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0],$us);
      ' 2>/dev/null) || TS="$(date -u +'%Y-%m-%d %H:%M:%S.000000')"

      STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-metrics"
      mkdir -p "$STATE_DIR" 2>/dev/null || true

      # ---------------------------------------------------------------------------
      # Pull identifiers from payload
      # ---------------------------------------------------------------------------
      SESSION_ID=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || echo "")
      _PAYLOAD_CWD=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || echo "")
      CWD="${_PAYLOAD_CWD:-$PWD}"
      CWD_HASH=$(printf '%s' "$CWD" | shasum -a 256 2>/dev/null | awk '{print $1}')

      # ---------------------------------------------------------------------------
      # Session duration tracking
      # ---------------------------------------------------------------------------
      EPOCH_MS=$(perl -MTime::HiRes=time -e 'printf("%d", time*1000)' 2>/dev/null || echo "0")
      DURATION_MS=""
      if [ -n "$SESSION_ID" ]; then
        _START_FILE="$STATE_DIR/session-${SESSION_ID}.start"
        case "$EVENT" in
          session_start)
            echo "$EPOCH_MS" > "$_START_FILE" 2>/dev/null || true
            ;;
          stop|session_end)
            if [ -r "$_START_FILE" ]; then
              _start_ms=$(cat "$_START_FILE" 2>/dev/null || echo "")
              if [ -n "$_start_ms" ]; then
                DURATION_MS=$(( EPOCH_MS - _start_ms ))
              fi
            fi
            [ "$EVENT" = "session_end" ] && rm -f "$_START_FILE" 2>/dev/null || true
            ;;
        esac
      fi

      # ---------------------------------------------------------------------------
      # Tool-specific token / model / message-id extraction
      # ---------------------------------------------------------------------------
      TOKENS_INPUT=""
      TOKENS_OUTPUT=""
      TOKENS_CACHE_READ=""
      TOKENS_CACHE_CREATION_CLAUDE=""
      TOKENS_REASONING_OUTPUT_CODEX=""
      MESSAGE_ID=""
      REQUEST_ID=""
      MODEL=""
      TOOL_VERSION=""
      QUOTA_WALL_ERROR=""
      QUOTA_WALL_TEXT=""
      API_ERROR_ERROR=""
      API_ERROR_TEXT=""

      if [ "$TOOL" = "claude" ]; then
        TRANSCRIPT_PATH=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
        case "$TRANSCRIPT_PATH" in
          "~/"*) TRANSCRIPT_PATH="${HOME}/${TRANSCRIPT_PATH#~/}" ;;
        esac

        if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
          # Last assistant message that has a usage block — that's the just-completed turn.
          LAST_ASSISTANT=$(jq -c 'select(.type=="assistant" and (.message.usage // false) != false)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
          if [ -n "$LAST_ASSISTANT" ]; then
            TOKENS_INPUT=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.input_tokens // empty')
            TOKENS_OUTPUT=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.output_tokens // empty')
            TOKENS_CACHE_READ=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.cache_read_input_tokens // empty')
            TOKENS_CACHE_CREATION_CLAUDE=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.cache_creation_input_tokens // empty')
            MESSAGE_ID=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.id // empty')
            REQUEST_ID=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.requestId // .request_id // empty')
            MODEL=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.model // empty')
          fi

          # Quota wall / api error detection from the last error row in the transcript
          LAST_ERR=$(jq -c 'select((.isApiErrorMessage // false) == true)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
          if [ -n "$LAST_ERR" ]; then
            _err_kind=$(printf '%s' "$LAST_ERR" | jq -r '.error // empty')
            _err_text=$(printf '%s' "$LAST_ERR" | jq -r '.message.content[0].text // empty')
            case "$EVENT" in
              stop)
                # Promote stop -> quota_wall / api_error when the last turn ended in error
                if [ "$_err_kind" = "rate_limit" ]; then
                  EVENT="quota_wall"
                  QUOTA_WALL_ERROR="$_err_kind"
                  QUOTA_WALL_TEXT="$_err_text"
                elif [ -n "$_err_kind" ]; then
                  EVENT="api_error"
                  API_ERROR_ERROR="$_err_kind"
                  API_ERROR_TEXT="$_err_text"
                fi
                ;;
              quota_wall)
                QUOTA_WALL_ERROR="$_err_kind"
                QUOTA_WALL_TEXT="$_err_text"
                ;;
              api_error)
                API_ERROR_ERROR="$_err_kind"
                API_ERROR_TEXT="$_err_text"
                ;;
            esac
          fi
        fi

        TOOL_VERSION=$(claude --version 2>/dev/null | awk '{print $1}' | head -n 1 || true)

      elif [ "$TOOL" = "codex" ]; then
        # Pick the newest rollout file — `cwd` and `turn-id` from the notify
        # payload could narrow this further, but newest-wins is correct in
        # practice (the rollout for the current session is the one just
        # appended to).
        ROLLOUT=$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -n 1)
        if [ -n "$ROLLOUT" ] && [ -r "$ROLLOUT" ]; then
          SESSION_ID=$(jq -r 'select((.type // "")=="session_meta" or (.payload.type // "")=="session_meta") | (.session_id // .payload.session_id // empty)' "$ROLLOUT" 2>/dev/null | head -n 1)
          MODEL=$(jq -r 'select((.payload.type // "")=="session_configured") | (.payload.model // empty)' "$ROLLOUT" 2>/dev/null | head -n 1)
          LAST_TC=$(jq -c 'select((.payload.type // "")=="token_count")' "$ROLLOUT" 2>/dev/null | tail -n 1)
          if [ -n "$LAST_TC" ]; then
            TOKENS_INPUT=$(printf '%s' "$LAST_TC" | jq -r '.payload.info.last_token_usage.input_tokens // empty')
            TOKENS_OUTPUT=$(printf '%s' "$LAST_TC" | jq -r '.payload.info.last_token_usage.output_tokens // empty')
            TOKENS_CACHE_READ=$(printf '%s' "$LAST_TC" | jq -r '.payload.info.last_token_usage.cached_input_tokens // empty')
            TOKENS_REASONING_OUTPUT_CODEX=$(printf '%s' "$LAST_TC" | jq -r '.payload.info.last_token_usage.reasoning_output_tokens // empty')
          fi
        fi
        TOOL_VERSION=$(codex --version 2>/dev/null | awk '{print $NF}' | head -n 1 || true)
      fi

      # ---------------------------------------------------------------------------
      # Compose payload
      # ---------------------------------------------------------------------------
      SUBJECT="${NATS_SUBJECT_PREFIX}.${TOOL}.${EVENT}.${HOST_NAME}.${USER_NAME}"
      EVENT_DATASET="agent-metrics.${TOOL}.${EVENT}"

      PAYLOAD=$(jq -cn \
        --arg customer_tenant   "$CUSTOMER_TENANT" \
        --arg customer_project  "$CUSTOMER_PROJECT" \
        --arg host_group        "$HOST_GROUP" \
        --arg host_name         "$HOST_NAME" \
        --arg event_module      "agent-metrics" \
        --arg event_dataset     "$EVENT_DATASET" \
        --arg timestamp         "$TS" \
        --arg level             "info" \
        --arg tool              "$TOOL" \
        --arg tool_version      "$TOOL_VERSION" \
        --arg event             "$EVENT" \
        --arg session_id        "$SESSION_ID" \
        --arg user              "$USER_NAME" \
        --arg model             "$MODEL" \
        --arg cwd_hash          "$CWD_HASH" \
        --arg message_id        "$MESSAGE_ID" \
        --arg request_id        "$REQUEST_ID" \
        --arg event_original    "$RAW_PAYLOAD" \
        --arg duration_ms       "$DURATION_MS" \
        --arg t_in              "$TOKENS_INPUT" \
        --arg t_out             "$TOKENS_OUTPUT" \
        --arg t_cr              "$TOKENS_CACHE_READ" \
        --arg t_cc              "$TOKENS_CACHE_CREATION_CLAUDE" \
        --arg t_rc              "$TOKENS_REASONING_OUTPUT_CODEX" \
        --arg qw_err            "$QUOTA_WALL_ERROR" \
        --arg qw_text           "$QUOTA_WALL_TEXT" \
        --arg ae_err            "$API_ERROR_ERROR" \
        --arg ae_text           "$API_ERROR_TEXT" \
        '
        def addn(k; v): if (v|tostring) != "" then . + {(k): (v|tonumber)} else . end;
        def adds(k; v): if (v|tostring) != "" then . + {(k): v} else . end;
        {
          customer_tenant:  $customer_tenant,
          customer_project: $customer_project,
          host_group:       $host_group,
          host_name:        $host_name,
          event_module:     $event_module,
          event_dataset:    $event_dataset,
          timestamp:        $timestamp,
          level:            $level,
          tool:             $tool,
          event:            $event,
          user:             $user,
          cwd_hash:         $cwd_hash,
          event_original:   $event_original
        }
        | adds("tool_version"; $tool_version)
        | adds("session_id";   $session_id)
        | adds("model";        $model)
        | adds("message_id";   $message_id)
        | adds("request_id";   $request_id)
        | addn("event_duration_ms";                 $duration_ms)
        | addn("tokens_turn_input";                 $t_in)
        | addn("tokens_turn_output";                $t_out)
        | addn("tokens_turn_cache_read";            $t_cr)
        | addn("tokens_turn_cache_creation_claude"; $t_cc)
        | addn("tokens_turn_reasoning_output_codex"; $t_rc)
        | adds("quota_wall_error"; $qw_err)
        | adds("quota_wall_text";  $qw_text)
        | adds("api_error_error";  $ae_err)
        | adds("api_error_text";   $ae_text)
        ' 2>/dev/null) || PAYLOAD=""

      [ -n "$PAYLOAD" ] || _bail "failed to build payload"

      # For quota_sample, extract flat rate_limits fields from the raw payload
      # (which is Claude Code's statusLine stdin JSON, forwarded by claude-metrics-statusline)
      if [ "$EVENT" = "quota_sample" ]; then
        EXTRA=$(printf '%s' "$RAW_PAYLOAD" | jq -c '
          {
            quota_five_hour_pct_used:        (.rate_limits.five_hour.used_percentage         // null),
            quota_five_hour_resets_at:       (.rate_limits.five_hour.resets_at               // null),
            quota_seven_day_pct_used:        (.rate_limits.seven_day.used_percentage         // null),
            quota_seven_day_resets_at:       (.rate_limits.seven_day.resets_at               // null),
            quota_seven_day_opus_pct_used:   (.rate_limits.seven_day_opus.used_percentage    // null),
            quota_seven_day_sonnet_pct_used: (.rate_limits.seven_day_sonnet.used_percentage  // null)
          } | with_entries(select(.value != null))
        ' 2>/dev/null)
        if [ -n "$EXTRA" ] && [ "$EXTRA" != "{}" ]; then
          PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c --argjson e "$EXTRA" '. + $e' 2>/dev/null || printf '%s' "$PAYLOAD")
        fi
      fi

      _log "subject=$SUBJECT"
      _log "payload=$PAYLOAD"

      # ---------------------------------------------------------------------------
      # Fire-and-forget publish. Never block the agent.
      # macOS doesn't ship timeout(1) — prefer gtimeout (coreutils), then
      # timeout, then fall back to no wrapper. The detached subshell with
      # disown guarantees we return immediately regardless.
      # ---------------------------------------------------------------------------
      _publish() {
        if command -v gtimeout >/dev/null 2>&1; then
          gtimeout 2s nats --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
        elif command -v timeout >/dev/null 2>&1; then
          timeout 2s nats --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
        else
          nats --server "$NATS_URL" --nkey "$NATS_NKEY_FILE" pub "$SUBJECT" "$PAYLOAD"
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

    bin.install "claude-metrics-emit"

    (buildpath/"claude-metrics-statusline").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-statusline
      #
      # Wraps Claude Code's statusLine. Captures the stdin JSON, and if
      # rate_limits is present, asynchronously emits a quota_sample event
      # (debounced to >=60s per change in used_percentage).
      #
      # Prints an empty status line by default.

      set -u

      STDIN=$(cat)
      STATE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-metrics/statusline-last"
      mkdir -p "$(dirname "$STATE")" 2>/dev/null || true

      if printf '%s' "$STDIN" | jq -e '.rate_limits' >/dev/null 2>&1; then
        NOW=$(date +%s)
        LAST_TIME=0
        LAST_FIVE=""
        if [ -r "$STATE" ]; then
          # shellcheck disable=SC1090
          . "$STATE" 2>/dev/null || true
        fi
        CUR_FIVE=$(printf '%s' "$STDIN" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || echo "")
        ELAPSED=$(( NOW - LAST_TIME ))
        if [ "$ELAPSED" -ge 60 ] && [ "$CUR_FIVE" != "$LAST_FIVE" ]; then
          printf 'LAST_TIME=%s\nLAST_FIVE=%s\n' "$NOW" "$CUR_FIVE" > "$STATE" 2>/dev/null || true
          printf '%s' "$STDIN" | claude-metrics-emit quota_sample >/dev/null 2>&1 || true
        fi
      fi

      echo ""
      exit 0
    BASH

    bin.install "claude-metrics-statusline"

    (buildpath/"claude-metrics-install-hooks").write <<~'BASH'
      #!/bin/bash
      # claude-metrics-install-hooks
      #
      # Wires the emitter into Claude Code (~/.claude/settings.json) and
      # Codex (~/.codex/config.toml). Idempotent: re-running strips any
      # prior entries tagged _managed_by=sandstorm-claude-metrics and
      # re-adds them.
      #
      # Refuses to overwrite a pre-existing .statusLine in Claude
      # settings, or a pre-existing notify=... in Codex config — prints
      # a diff for manual merge instead.

      set -euo pipefail

      MANAGED="sandstorm-claude-metrics"
      CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
      CODEX_CONF="${HOME}/.codex/config.toml"

      command -v jq >/dev/null 2>&1 || { echo "❌ jq is required — run: brew install jq" >&2; exit 1; }

      install_claude_hooks() {
        mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
        [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

        local tmp tmp2
        tmp=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")

        # Filter out any prior managed entries, then append fresh ones.
        # Tag lives at .hooks[0]._managed_by inside each entry.
        jq --arg m "$MANAGED" '
          def keep: map(select((.hooks[0]._managed_by // "") != $m));
          .hooks //= {}
          | .hooks.SessionStart     = (((.hooks.SessionStart     // []) | keep)
              + [{hooks:[{type:"command",command:"claude-metrics-emit session_start",_managed_by:$m}]}])
          | .hooks.UserPromptSubmit = (((.hooks.UserPromptSubmit // []) | keep)
              + [{hooks:[{type:"command",command:"claude-metrics-emit prompt",_managed_by:$m}]}])
          | .hooks.Stop             = (((.hooks.Stop             // []) | keep)
              + [{hooks:[{type:"command",command:"claude-metrics-emit stop",_managed_by:$m}]}])
          | .hooks.SessionEnd       = (((.hooks.SessionEnd       // []) | keep)
              + [{hooks:[{type:"command",command:"claude-metrics-emit session_end",_managed_by:$m}]}])
        ' "$CLAUDE_SETTINGS" > "$tmp"

        # statusLine — only set if not already configured.
        if jq -e '.statusLine' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
          echo "⚠️  $CLAUDE_SETTINGS already has a .statusLine — leaving it untouched." >&2
          echo "    For live quota samples, change your statusLine command to:" >&2
          echo "        claude-metrics-statusline" >&2
          echo "    (or wrap it so claude-metrics-statusline sees the stdin payload)." >&2
        else
          tmp2=$(mktemp "${TMPDIR:-/tmp}/claude-metrics-XXXXXXXX")
          jq '. + {statusLine: {type:"command", command:"claude-metrics-statusline"}}' "$tmp" > "$tmp2"
          mv "$tmp2" "$tmp"
        fi

        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "✅ Updated $CLAUDE_SETTINGS"
      }

      install_codex_notify() {
        if [ ! -f "$CODEX_CONF" ]; then
          echo "ℹ️  $CODEX_CONF doesn't exist — skipping Codex install (run codex once to create it)."
          return 0
        fi
        if grep -E '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONF" >/dev/null 2>&1; then
          echo "⚠️  $CODEX_CONF already has a 'notify = ...' line — not overwriting." >&2
          echo "    For Codex metrics, change it to:" >&2
          echo "        notify = [\"claude-metrics-emit\", \"codex-notify\"]" >&2
          return 0
        fi
        {
          echo ""
          echo "# Added by claude-metrics-install-hooks"
          echo 'notify = ["claude-metrics-emit", "codex-notify"]'
        } >> "$CODEX_CONF"
        echo "✅ Updated $CODEX_CONF"
      }

      install_claude_hooks
      install_codex_notify

      cat <<EOM

      Done.

      Next:
        0. Install the nats CLI (if not done):
             brew install nats-io/nats-tools/nats
        1. Create ~/.config/claude-metrics/nats.conf — see the example at
             $(brew --prefix)/share/claude-metrics/nats.conf.example
        2. Drop your nkey seed at ~/.config/claude-metrics/submission-key.nkey
           and chmod 600 it:
             chmod 600 ~/.config/claude-metrics/submission-key.nkey
        3. Verify connectivity:
             echo '{}' | CLAUDE_METRICS_DEBUG=1 claude-metrics-emit session_start

      EOM
    BASH

    bin.install "claude-metrics-install-hooks"

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

      Hook-driven usage metrics for Claude Code and Codex (OpenAI),
      published to a central NATS server.

      ## Install

          brew install sandstorm/tap/claude-metrics
          claude-metrics-install-hooks

      ## Configure

      Create `~/.config/claude-metrics/nats.conf` (see `nats.conf.example`
      installed alongside this README) and drop the NATS nkey seed at
      `~/.config/claude-metrics/submission-key.nkey` (mode 0600):

          install -m 600 /dev/stdin ~/.config/claude-metrics/submission-key.nkey <<<"SU...your seed..."

      ## Verify

          CLAUDE_METRICS_DEBUG=1 echo '{}' | claude-metrics-emit session_start

      ## Opt out

      Remove or rename `~/.config/claude-metrics/nats.conf`. The emitter
      exits silently when its config is missing.
    MD

    (share/"claude-metrics").install "nats.conf.example", "USAGE.md"
  end

  def caveats
    <<~EOS
      Required dependencies (not auto-installed — any homebrew/core dep forces
      cloning that tap, which fails on machines where it isn't already tapped):
        brew install jq
        brew install nats-io/nats-tools/nats

      To enable metrics emission:

        1. Wire the hooks into Claude Code & Codex:
             claude-metrics-install-hooks

        2. Configure NATS:
             mkdir -p ~/.config/claude-metrics
             cp #{share}/claude-metrics/nats.conf.example ~/.config/claude-metrics/nats.conf
             # …edit nats.conf, then drop your nkey seed:
             chmod 600 ~/.config/claude-metrics/submission-key.nkey

        3. Verify (with debug):
             echo '{}' | CLAUDE_METRICS_DEBUG=1 claude-metrics-emit session_start

      Opt out by removing ~/.config/claude-metrics/nats.conf.
    EOS
  end

  test do
    assert_predicate bin/"claude-metrics-emit", :executable?
    assert_predicate bin/"claude-metrics-install-hooks", :executable?
    assert_predicate bin/"claude-metrics-statusline", :executable?

    # With no config, emitter must exit 0 silently.
    ENV["HOME"] = testpath.to_s
    assert_equal "", shell_output("echo '{}' | #{bin}/claude-metrics-emit session_start")
  end
end
