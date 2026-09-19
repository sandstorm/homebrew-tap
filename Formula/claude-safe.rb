# typed: false
# frozen_string_literal: true

class ClaudeSafe < Formula
  desc "Claude Code wrapped with agent-safehouse sandboxing"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "2.13.0"

  depends_on :macos
  depends_on "eugene1g/safehouse/agent-safehouse"

  def install
    (buildpath/"claude-safe").write <<~EOS
      #!/bin/bash

      # Custom profiles installed alongside this script.
      # Names listed here are mapped to --append-profile=PROFILES_DIR/NAME.sb
      # Everything else is passed through to safehouse as --enable=NAME.
      CUSTOM_PROFILES=(env git flutter mistral codex vault)
      PROFILES_DIR="#{share}/profiles"

      # DS4 (https://dwarfstar.sh) is a local inference engine that is used from
      # its checkout directory (./ds4, ./ds4-agent, helper scripts, model weights)
      # — it is not installed on PATH. The checkout is not always in the same
      # place, so these are overridable from ~/.zshrc.
      DS4_HOME="${DS4_HOME:-$HOME/src/ds4}"
      DS4_MODELS="${DS4_MODELS:-$DS4_HOME/models}"
      DS4_CACHE="${DS4_CACHE:-$HOME/.ds4}"

      usage() {
        cat <<EOF
      Usage: $(basename "$0")  [options] [-- claude-args...]
             vibe-safe        [options] [-- vibe-args...]
             codex-safe       [options] [-- codex-args...]
             ds4-safe         [options] [-- ds4-args...]
             ds4-agent-safe   [options] [-- ds4-agent-args...]

      WHAT CLAUDE-SAFE DOES
        Runs Claude Code (or Vibe for Mistral Code, Codex for OpenAI, or DS4 /
        DS4-agent for local inference) inside an agent-safehouse sandbox.
        By default, the agent can ONLY read/write the current directory.

      DEFAULT RESTRICTIONS (Sandstorm policy)
        .env files        blocked (read+write)   re-enable: --enable=env
        .git folder       blocked (read+write)   re-enable: --enable=git
        .vault files      blocked (read+write)   re-enable: --enable=vault
        ~/.kube           blocked (read+write)   NOT re-enableable (too dangerous)
        .dev.vars files   blocked (read)         NOT re-enableable
        *.key             blocked (read)         NOT re-enableable
        secrets/          blocked (read+write)   NOT re-enableable
        credentials/      blocked (read+write)   NOT re-enableable
        .aws/             blocked (read+write)   NOT re-enableable
        .ssh/             blocked (read+write)   NOT re-enableable
        .npmrc / .pypirc  blocked (read)         NOT re-enableable
        config/database.yml, config/credentials.json
                          blocked (read)         NOT re-enableable
        bw / rbw          blocked (exec+read)    Bitwarden CLIs
        localhost         blocked (network)       re-enable: --allow-localhost[=PORTS]

      CUSTOM PROFILES (claude-safe specific)
        --enable=env        Re-allow .env file access
        --enable=git        Re-allow .git folder access
        --enable=flutter    Flutter/Dart toolchain + .git access
        --enable=mistral    Vibe config (~/.vibe) — auto-enabled by vibe-safe
        --enable=codex      Codex config (~/.codex) — auto-enabled by codex-safe
        --enable=vault      Re-allow .vault file access
        --enable=localhost  Re-allow ALL localhost ports (= --allow-localhost)
        --enable=sdd        SDD decision-graph skill — required for the /sdd skill.
                            Re-allows localhost binding (Claude Code's own nested
                            sandbox proxy needs it) + .git access.

      SAFEHOUSE FEATURES (pass-through, comma-separated)
        --enable=FEATURES   1password, agent-browser, browser-native-messaging,
                            chromium-full, chromium-headless, cleanshot, clipboard,
                            cloud-credentials, cloud-storage, docker, electron,
                            keychain, kubectl, lldb, macos-gui, microphone,
                            playwright-chrome, process-control, shell-init,
                            spotlight, ssh, vscode, xcode,
                            all-agents, all-apps, wide-read

      DIRECTORY ACCESS
        --add-dirs-ro=PATHS   Colon-separated read-only paths
        --add-dirs=PATHS      Colon-separated read/write paths
        --workdir=DIR         Override working directory (default: .)

      ENVIRONMENT
        --env                 Pass full host environment to agent
        --env=FILE            Source FILE for env vars (bash syntax)
        --env-pass=NAMES      Comma-separated env var names to pass through

      OTHER SAFEHOUSE OPTIONS
        --append-profile=PATH Additional sandbox profile file
        --trust-workdir-config Load .safehouse from workdir
        --explain             Print effective grants summary to stderr
        --stdout              Print policy text (don't execute)

      NETWORK ISOLATION
        --allow-localhost=PORTS     Comma-separated localhost ports to whitelist
                                    Example: --allow-localhost=3000,5432
        --allow-localhost           ALL localhost ports (no port list)
        --allow-localhost=all       Same as the bare flag
        --enable=localhost          Same as the bare flag

      DS4 (https://dwarfstar.sh) — local inference engine
        ds4-safe             Interactive DS4 chat, sandboxed
        ds4-agent-safe       DS4 coding agent, sandboxed (in-process, no server)

        DS4 lives in a checkout, not on PATH. Configure it in ~/.zshrc:
          export DS4_HOME=~/src/ds4      # checkout  (default: ~/src/ds4)
          export DS4_MODELS=/Volumes/ssd/ds4-models
                                        # weights    (default: \\$DS4_HOME/models)
          export DS4_CACHE=~/.ds4        # config + KV cache (default: ~/.ds4)

        Inside the sandbox DS4 gets: \\$DS4_HOME and \\$DS4_MODELS read+execute,
        \\$DS4_CACHE and ~/.ds4_history / ~/.ds4_agent_history read+write.
        Everything else stays under the normal claude-safe restrictions.

      EXAMPLES
        claude-safe                           Basic sandboxed Claude
        claude-safe --enable=docker           Allow Docker commands
        claude-safe --enable=docker,env       Docker + .env access
        claude-safe --add-dirs-ro=../shared   Read access to sibling dir
        claude-safe -- --resume               Pass --resume to Claude

        claude-safe --allow-localhost=3000    Allow only localhost:3000
        claude-safe --allow-localhost         Allow all localhost ports

        ds4-safe                              Sandboxed DS4 chat
        ds4-agent-safe --enable=git           DS4 agent with .git access

      MORE INFO
        safehouse -h          Full safehouse documentation
        claude-unsafe -h      Claude without sandbox
        ds4-unsafe -h         DS4 without sandbox

      EOF
      }

      for arg in "$@"; do
        case "$arg" in
          -h|--help) usage; exit 0 ;;
        esac
      done

      # Detect --mistral, --codex, --ds4, --ds4-agent and --allow-localhost flags,
      # strip them from the arg list
      cmd="claude"
      allow_localhost_ports=""
      allow_localhost_all=false
      _filtered=()
      for arg in "$@"; do
        if [[ "$arg" == "--mistral" ]]; then
          cmd="vibe"
        elif [[ "$arg" == "--codex" ]]; then
          cmd="codex"
        elif [[ "$arg" == "--ds4" ]]; then
          cmd="ds4"
        elif [[ "$arg" == "--ds4-agent" ]]; then
          cmd="ds4-agent"
        elif [[ "$arg" == "--allow-localhost" ]]; then
          # Bare flag (no =PORTS) → all localhost ports
          allow_localhost_all=true
        elif [[ "$arg" == --allow-localhost=* ]]; then
          _value="${arg#--allow-localhost=}"
          if [[ "$_value" == "all" || "$_value" == "*" || -z "$_value" ]]; then
            allow_localhost_all=true
          else
            allow_localhost_ports="$_value"
          fi
        else
          _filtered+=("$arg")
        fi
      done
      set -- "${_filtered[@]}"

      if [[ "$cmd" == "vibe" ]] && ! command -v vibe &>/dev/null; then
        echo "Error: vibe (Mistral CLI) is not installed. Run: brew install mistral-vibe" >&2
        exit 1
      fi

      if [[ "$cmd" == "codex" ]] && ! command -v codex &>/dev/null; then
        echo "Error: codex (OpenAI CLI) is not installed. Run: brew install --cask codex" >&2
        exit 1
      fi

      # DS4 is run from its checkout by absolute path — it is not on PATH.
      ds4_mode=false
      if [[ "$cmd" == "ds4" || "$cmd" == "ds4-agent" ]]; then
        ds4_mode=true
        _ds4_bin="${DS4_HOME}/${cmd}"
        if [[ ! -x "$_ds4_bin" ]]; then
          echo "Error: DS4 executable not found at $_ds4_bin" >&2
          echo "       Install DS4 from https://dwarfstar.sh, then point DS4_HOME at" >&2
          echo "       the checkout in your ~/.zshrc, e.g.:" >&2
          echo "         export DS4_HOME=~/src/ds4" >&2
          exit 1
        fi
        cmd="$_ds4_bin"
      fi

      if [[ "$cmd" == "vibe" ]]; then
        set -- "--enable=mistral" "$@"
      elif [[ "$cmd" == "codex" ]]; then
        set -- "--enable=codex" "$@"
      fi

      # Expand a comma-separated enable value.
      # Custom names  → --append-profile=PROFILES_DIR/NAME.sb (null-delimited output)
      # Other names   → --enable=NAME
      _expand_enable() {
        local value="$1"
        local name
        local IFS=','
        for name in $value; do
          local p is_custom=false
          for p in "${CUSTOM_PROFILES[@]}"; do
            [[ "$p" == "$name" ]] && is_custom=true && break
          done
          if $is_custom; then
            printf '%s\\0' "--append-profile=${PROFILES_DIR}/${name}.sb"
          else
            printf '%s\\0' "--enable=${name}"
          fi
        done
      }

      # --enable=sdd and --enable=localhost are handled specially: they re-allow
      # localhost, which must be appended AFTER network-isolation.sb to win (SBPL
      # is last-match-wins). So we pull those names out of the --enable value
      # here, set a flag, and append the grants later (see below). Runs in the
      # parent shell (not a subshell) so it can set the flags.
      enable_sdd=false
      _enable_filtered=""
      _filter_sdd() {
        local value="$1" name
        local out=()
        local IFS=','
        for name in $value; do
          if [[ "$name" == "sdd" ]]; then
            enable_sdd=true
          elif [[ "$name" == "localhost" ]]; then
            # --enable=localhost is a synonym for --allow-localhost (all ports)
            allow_localhost_all=true
          else
            out+=("$name")
          fi
        done
        _enable_filtered="${out[*]}"
      }

      # Pre-process args: expand --enable=a,b and --enable a,b forms.
      expanded=()
      args=("$@")
      i=0
      while [[ $i -lt ${#args[@]} ]]; do
        arg="${args[$i]}"
        if [[ "$arg" == --enable=* ]]; then
          _filter_sdd "${arg#--enable=}"
          if [[ -n "$_enable_filtered" ]]; then
            while IFS= read -r -d '' token; do
              expanded+=("$token")
            done < <(_expand_enable "$_enable_filtered")
          fi
        elif [[ "$arg" == "--enable" && $((i+1)) -lt ${#args[@]} ]]; then
          ((i++))
          _filter_sdd "${args[$i]}"
          if [[ -n "$_enable_filtered" ]]; then
            while IFS= read -r -d '' token; do
              expanded+=("$token")
            done < <(_expand_enable "$_enable_filtered")
          fi
        else
          expanded+=("$arg")
        fi
        ((i++))
      done

      safehouse_args=()
      claude_args=()
      found_sep=false
      for arg in "${expanded[@]}"; do
        if ! $found_sep && [[ "$arg" == "--" ]]; then
          found_sep=true
        elif $found_sep; then
          claude_args+=("$arg")
        else
          safehouse_args+=("$arg")
        fi
      done
      # ---------------------------------------------------------------------------
      # Install Claude Code skills (idempotent — skips if symlink already exists)
      # ---------------------------------------------------------------------------
      _claude_install_skill() {
        local repo="$1" ref="$2" subdir="$3"
        local owner="${repo%%/*}" reponame="${repo##*/}"
        local skill_name
        skill_name="$(basename "$subdir")"
        local clone_dir="${HOME}/.claude/.skills/${owner}-${reponame}"
        local link="${HOME}/.claude/skills/${skill_name}"

        [ -L "$link" ] && return 0  # already installed

        if [ ! -d "$clone_dir/.git" ]; then
          echo "📦 Installing skill: $skill_name ..." >&2
          git clone "https://github.com/${repo}" "$clone_dir" --quiet
        else
          git -C "$clone_dir" fetch --all --tags --quiet
        fi

        git -C "$clone_dir" checkout "$ref" --quiet

        local target="$clone_dir/$subdir"
        if [ ! -d "$target" ]; then
          echo "⚠️  Skill subdir '$subdir' not found in $clone_dir, skipping." >&2
          return 1
        fi

        mkdir -p "${HOME}/.claude/skills"
        ln -s "$target" "$link"

        local sha
        sha=$(git -C "$clone_dir" rev-parse --short HEAD)
        echo "✅ Skill $skill_name installed: $link -> $target @ $sha" >&2
      }

      if [[ "$cmd" == "claude" ]]; then
        _claude_install_skill "mattpocock/skills" "b2039ab896a01ebcc539704f69974f7bcdfb1226" "tdd"
      fi

      # ---------------------------------------------------------------------------
      # Network isolation — blocks localhost by default
      # ---------------------------------------------------------------------------
      safehouse_args+=("--append-profile=${PROFILES_DIR}/network-isolation.sb")

      # --enable=sdd: re-allow localhost binding (+ .git). MUST come after
      # network-isolation.sb so its localhost allows override the localhost denies.
      if [[ "$enable_sdd" == true ]]; then
        safehouse_args+=("--append-profile=${PROFILES_DIR}/sdd.sb")
      fi

      # Temp profiles generated below are cleaned up on exit.
      _tmpprofiles=()
      trap 'rm -f "${_tmpprofiles[@]}"' EXIT

      _mktemp_profile() {
        local f
        f=$(mktemp "${TMPDIR:-/tmp}/claude-safe-$1-XXXXXX")
        mv "$f" "${f}.sb"
        _tmpprofiles+=("${f}.sb")
        printf '%s' "${f}.sb"
      }

      # ---------------------------------------------------------------------------
      # DS4 (https://dwarfstar.sh)
      #
      # DS4 is run from a checkout whose location differs per machine, so the
      # grants cannot live in a static .sb file — they are generated here from
      # DS4_HOME / DS4_MODELS / DS4_CACHE.
      #
      #   $DS4_HOME    read + execute  (ds4, ds4-agent, helper scripts)
      #   $DS4_MODELS  read            (model weights; may live outside DS4_HOME)
      #   $DS4_CACHE   read + write    (config + KV cache, default ~/.ds4)
      #   ~/.ds4_history, ~/.ds4_agent_history   read + write
      #
      # Appended AFTER the guards profile so these allows win (SBPL is
      # last-match-wins) — e.g. model files under a path the guards would
      # otherwise deny.
      # ---------------------------------------------------------------------------
      if [[ "$ds4_mode" == true ]]; then
        mkdir -p "$DS4_CACHE"

        _ds4profile=$(_mktemp_profile ds4)
        cat > "$_ds4profile" <<EOSB
      (version 1)
      (allow process-exec* file-read* (subpath "$DS4_HOME"))
      (allow file-read* (subpath "$DS4_MODELS"))
      (allow file-read* file-write* (subpath "$DS4_CACHE"))
      (allow file-read* file-write*
        (literal "$HOME/.ds4_history")
        (literal "$HOME/.ds4_agent_history"))
      EOSB
        safehouse_args+=("--append-profile=$_ds4profile")

        # Also tell safehouse about the directories, so its own bookkeeping
        # (and --explain output) matches the profile above.
        safehouse_args+=("--add-dirs-ro=${DS4_HOME}:${DS4_MODELS}")
        safehouse_args+=("--add-dirs=${DS4_CACHE}")
      fi

      # Generate temp profile for --allow-localhost / --allow-localhost=PORTS.
      # Appended after network-isolation.sb, so these allows override its denies.
      if [[ "$allow_localhost_all" == true || -n "$allow_localhost_ports" ]]; then
        _tmpprofile=$(_mktemp_profile localhost)
        echo '(version 1)' > "$_tmpprofile"
        if [[ "$allow_localhost_all" == true ]]; then
          # All ports — "*" as the port in an (ip) filter matches any port.
          cat >> "$_tmpprofile" <<EOSB
      (allow network-outbound (remote ip "localhost:*"))
      (allow network-bind (local ip "localhost:*"))
      (allow network-inbound (local ip "localhost:*"))
      EOSB
        else
          IFS=',' read -ra _ports <<< "$allow_localhost_ports"
          for _port in "${_ports[@]}"; do
            cat >> "$_tmpprofile" <<EOSB
      (allow network-outbound (remote ip "localhost:$_port"))
      (allow network-bind (local ip "localhost:$_port"))
      (allow network-inbound (local ip "localhost:$_port"))
      EOSB
          done
        fi
        safehouse_args+=("--append-profile=$_tmpprofile")
      fi

      exec env SAFEHOUSE_WORKDIR=. safehouse \
        --append-profile="#{share}/sandstorm-additional-claude-safe-guards.sb" \
        --append-profile="#{share}/profiles/claude-metrics.sb" \
        "${safehouse_args[@]}" -- "$cmd" "${claude_args[@]}"

      EOS

    bin.install "claude-safe"

    (buildpath/"vibe-safe").write <<~EOS
      #!/bin/bash
      exec "#{bin}/claude-safe" --mistral "$@"
    EOS

    bin.install "vibe-safe"

    (buildpath/"codex-safe").write <<~EOS
      #!/bin/bash
      exec "#{bin}/claude-safe" --codex "$@"
    EOS

    bin.install "codex-safe"

    (buildpath/"ds4-safe").write <<~EOS
      #!/bin/bash
      exec "#{bin}/claude-safe" --ds4 "$@"
    EOS

    bin.install "ds4-safe"

    (buildpath/"ds4-agent-safe").write <<~EOS
      #!/bin/bash
      exec "#{bin}/claude-safe" --ds4-agent "$@"
    EOS

    bin.install "ds4-agent-safe"

    (buildpath/"aliases.zsh").write <<~EOS
      # Managed by brew install sandstorm/tap/claude-safe — do not edit manually
      # This file is updated automatically when the formula is upgraded.

      # Save original claude path before overriding
      if command -v claude &>/dev/null; then
        _claude_original="$(command -v claude)"
      fi

      claude() {
        echo "⚠️  Use 'claude-safe' for sandboxed Claude (recommended) or 'claude-unsafe' for unrestricted access." >&2
        return 1
      }

      claude-unsafe() {
        if [[ -n "$_claude_original" ]]; then
          "$_claude_original" "$@"
        else
          command claude "$@"
        fi
      }

      # Save original vibe path before overriding
      if command -v vibe &>/dev/null; then
        _vibe_original="$(command -v vibe)"
      fi

      vibe() {
        echo "⚠️  Use 'vibe-safe' for sandboxed Vibe (recommended) or 'vibe-unsafe' for unrestricted access." >&2
        return 1
      }

      vibe-unsafe() {
        if [[ -n "$_vibe_original" ]]; then
          "$_vibe_original" "$@"
        else
          command vibe "$@"
        fi
      }

      # Save original codex path before overriding
      if command -v codex &>/dev/null; then
        _codex_original="$(command -v codex)"
      fi

      codex() {
        echo "⚠️  Use 'codex-safe' for sandboxed Codex (recommended) or 'codex-unsafe' for unrestricted access." >&2
        return 1
      }

      codex-unsafe() {
        if [[ -n "$_codex_original" ]]; then
          "$_codex_original" "$@"
        else
          command codex "$@"
        fi
      }

      # DS4 (https://dwarfstar.sh) — local inference engine.
      # DS4 lives in a checkout and is normally invoked as ./ds4 from there.
      # Set DS4_HOME in this file (before sourcing aliases.zsh) if your checkout
      # is not at ~/src/ds4:
      #   export DS4_HOME=~/src/ds4
      # Optional: DS4_MODELS (weights, default $DS4_HOME/models)
      #           DS4_CACHE  (config + KV cache, default ~/.ds4)

      ds4() {
        echo "⚠️  Use 'ds4-safe' for sandboxed DS4 (recommended) or 'ds4-unsafe' for unrestricted access." >&2
        return 1
      }

      ds4-agent() {
        echo "⚠️  Use 'ds4-agent-safe' for the sandboxed DS4 agent (recommended) or 'ds4-agent-unsafe' for unrestricted access." >&2
        return 1
      }

      # Runs the DS4 binary from the checkout, without a sandbox.
      _ds4_run_unsafe() {
        local name="$1"; shift
        local home="${DS4_HOME:-$HOME/src/ds4}"
        if [[ ! -x "$home/$name" ]]; then
          echo "Error: DS4 executable not found at $home/$name" >&2
          echo "       Set DS4_HOME in your ~/.zshrc to your DS4 checkout." >&2
          return 1
        fi
        # Run from the current directory (like ds4-safe does), not from the checkout.
        "$home/$name" "$@"
      }

      ds4-unsafe() {
        _ds4_run_unsafe ds4 "$@"
      }

      ds4-agent-unsafe() {
        _ds4_run_unsafe ds4-agent "$@"
      }
    EOS

    share.install "aliases.zsh"

    (buildpath/"sandstorm-additional-claude-safe-guards.sb").write <<~EOS
      ;; safehouse profile with additional restriction for claude
      ;; - deny .env files — reads and writes
      ;; - deny .git - reads and writes
      ;; - deny .vault files — reads and writes
      ;; - deny bw (Bitwarden CLI) — execution and reads
      ;; - deny rbw (inofficial Bitwarden CLI) — execution and reads
      ;; - allow OrbStack binary

      (version 1)

      ;; ---------------------------------------------------------------------------
      ;; deny .env files — reads and writes
      ;;
      ;; Although not checked in, local .env files might contain secrets for
      ;; local development. We must not share those with claude.
      ;;
      ;; Covers:
      ;;   .env                  (root of any allowed subpath)
      ;;   .env.*                (any suffix — caught by the regex rule below)
      ;;   .env_*                (any suffix — caught by the regex rule below)
      ;;
      ;; macOS sandbox-exec does not support glob/wildcard path matching in
      ;; (literal) or (subpath) rules. For suffix-based matching you must use
      ;; (regex). The pattern below matches any absolute path whose last
      ;; component starts with ".env" — with or without a suffix.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        ;; .env .env.dev .env_dev …
        (regex #"/[.]env([._][^/]*)?$")
        ;; http-client.env.json http-client.private.env.json …
        (regex #"/[^/]*[.]env[.](json|yaml|yml)?$")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny .git - reads and writes
      ;;
      ;; The git history is of no concern for claude. It should not contain sensible
      ;; information but just in case.
      ;;
      ;; Covers:
      ;;   .git                  (root of any allowed subpath)
      ;;
      ;; macOS sandbox-exec does not support glob/wildcard path matching in
      ;; (literal) or (subpath) rules. For suffix-based matching you must use
      ;; (regex). The pattern below matches any absolute path whose last
      ;; component starts with ".env" — with or without a suffix.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        (regex #"/\.git/")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny .vault files — reads and writes
      ;;
      ;; Vault-related files may contain secrets (Ansible Vault passwords,
      ;; HashiCorp Vault configs, etc.).
      ;;
      ;; Covers:
      ;;   .vault, .vault.yml, .vault_pass    (dotfiles starting with .vault)
      ;;   vault, vault.yml, vault-secrets    (files/dirs starting with vault)
      ;;
      ;; The regex /vault ensures vault appears right after a /, i.e. at the
      ;; start of a path component — so /somevault will NOT match.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        (regex #"/\.vault([^/]*)?$")
        (regex #"/\.vault[^/]*/")
        (regex #"/vault([^/]*)?$")
        (regex #"/vault[^/]*/")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny .dev.vars files — reads
      ;;
      ;; Cloudflare Workers / Wrangler local secrets files.
      ;; NOT re-enableable.
      ;; ---------------------------------------------------------------------------

      (deny file-read*
        (regex #"/\\.dev\\.vars([^/]*)?$")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny private key files — reads
      ;;
      ;; Covers *.key: SSH/GPG/TLS private keys.
      ;; *.pem is intentionally not blocked because Python/Vibe may need
      ;; CA bundles such as certifi/cacert.pem for TLS verification.
      ;; NOT re-enableable.
      ;; ---------------------------------------------------------------------------

      (deny file-read*
        (regex #"/[^/]*\\.key$")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny secrets/ and credentials/ directories — reads and writes
      ;;
      ;; Matches any path component named "secrets" or "credentials".
      ;; NOT re-enableable.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        (regex #"/secrets(/|$)")
        (regex #"/credentials(/|$)")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny .aws/ and .ssh/ directories — reads and writes
      ;;
      ;; Cloud credentials and SSH key material. NOT re-enableable.
      ;; SSH agent socket access via safehouse --enable=ssh is unaffected.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        (regex #"/\\.aws(/|$)")
        (regex #"/\\.ssh(/|$)")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny sensitive config and token files — reads
      ;;
      ;; Covers: Rails DB config, app credentials JSON, npm auth token, PyPI token.
      ;; NOT re-enableable.
      ;; ---------------------------------------------------------------------------

      (deny file-read*
        (regex #"/config/database\\.yml$")
        (regex #"/config/credentials\\.json$")
        (regex #"/\\.npmrc$")
        (regex #"/\\.pypirc$")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny bw (Bitwarden CLI) — execution and reads
      ;;
      ;; Blocks the agent from running `bw`
      ;;
      ;; exec* covers process-exec and process-exec-interpreter so the binary
      ;; cannot be launched directly or via a shebang wrapper.
      ;; file-read* on the same regex prevents the agent from reading the binary
      ;; itself (e.g. to inspect or copy it).
      ;; ---------------------------------------------------------------------------

      (deny process-exec* file-read*
        (regex #"(^|/)bw$")
      )

      ;; ---------------------------------------------------------------------------
      ;; deny rbw (inofficial Bitwarden CLI) — execution and reads
      ;;
      ;; Blocks the agent from running `rbw`
      ;;
      ;; exec* covers process-exec and process-exec-interpreter so the binary
      ;; cannot be launched directly or via a shebang wrapper.
      ;; file-read* on the same regex prevents the agent from reading the binary
      ;; itself (e.g. to inspect or copy it).
      ;; ---------------------------------------------------------------------------

      (deny process-exec* file-read*
        (regex #"(^|/)rbw$")
      )
      
      ;; ---------------------------------------------------------------------------
      ;; deny ~/.kube — reads and writes
      ;;
      ;; The ~/.kube directory contains kubeconfig files with cluster credentials,
      ;; client certificates, and tokens. Leaking these could grant full access
      ;; to Kubernetes clusters. This MUST NOT be accessible under any circumstances.
      ;; ---------------------------------------------------------------------------

      (deny file-read* file-write*
        (home-subpath "/.kube")
      )

      ;; ---------------------------------------------------------------------------
      ;; allow OrbStack binary
      ;;
      ;; the actual usage is restricted with --enable=docker (which already supports the OrbStack socket)
      ;; ---------------------------------------------------------------------------

      (allow process-exec* file-read*
        (subpath "/Applications/OrbStack.app/")
      )

      ;; ---------------------------------------------------------------------------
      ;; allow Shottr screenshot temp dir — reads only
      ;;
      ;; Shottr (screenshot tool) drops captures here. Claude needs to read them
      ;; when the user shares a screenshot. home-subpath resolves per-user, so this
      ;; works for arbitrary users (not just one hardcoded home).
      ;; ---------------------------------------------------------------------------

      (allow file-read*
        (home-subpath "/Library/Containers/cc.ffitch.shottr/Data/tmp/cc.ffitch.shottr")
      )
    EOS

    share.install "sandstorm-additional-claude-safe-guards.sb"

    # Custom profiles — activated via --enable=NAME
    (buildpath/"profiles/env.sb").write <<~EOS
      ;; Custom sandbox profile: env
      ;;
      ;; Re-enables access to things blocked by sandstorm-additional-claude-safe-guards.sb:
      ;;   - .env files (read + write)
      ;;
      ;; Activated via: claude-safe --enable=env

      (version 1)

      ;; Re-allow .env files
      (allow file-read* file-write*
        ;; .env .env.dev .env_dev …
        (regex #"/[.]env([._][^/]*)?$")
        ;; http-client.env.json http-client.private.env.json …
        (regex #"/[^/]*[.]env[.](json|yaml|yml)?$")
      )
    EOS

    (buildpath/"profiles/git.sb").write <<~EOS
      ;; Custom sandbox profile: git
      ;;
      ;; Re-enables access to things blocked by sandstorm-additional-claude-safe-guards.sb:
      ;;   - .git folder (read + write)
      ;;
      ;; Activated via: claude-safe --enable=git

      (version 1)

      (allow file-read* file-write*
        (regex #"/\.git/")
      )
    EOS

    (buildpath/"profiles/flutter.sb").write <<~EOS
      ;; Custom sandbox profile: flutter
      ;;
      ;; Re-enables access to things blocked by sandstorm-additional-claude-safe-guards.sb:
      ;;   - .git folder (read + write)
      ;; Re-enables access to things blockes by safehouse defaults:
      ;;   - $HOME/.config/flutter (read + write)
      ;;   - $HOME/.dart-tool (read + write)
      ;;   - $HOME/.pub-cache (read + write)
      ;;   - $HOME/.dartServer (read + write)
      ;;   - $HOME/.local/share/mise (read + write)
      ;;   - $HOME/.android (read + write)
      ;;   - /opt/homebrew/share/android-commandlinetools (read)
      ;;
      ;; Activated via: claude-safe --enable=flutter

      (version 1)

      (allow file-read*
        (regex #"/\.git/")
        (regex #"^/opt/homebrew/share/android-commandlinetools/") ;; --add-dirs-ro=/opt/homebrew/share/android-commandlinetools
      )
      (allow file-read* file-write*
          (home-subpath "/.config/flutter")         ;; --add-dirs=$HOME/.config/flutter
          (home-subpath "/.dart-tool")              ;; --add-dirs=$HOME/.dart-tool
          (home-subpath "/.pub-cache")              ;; --add-dirs=$HOME/.pub-cache
          (home-subpath "/.dartServer")             ;; --add-dirs=$HOME/.dartServer
          (home-subpath "/.local/share/mise")       ;; --add-dirs=$HOME/.local/share/mise
          (home-subpath "/.android")                ;; --add-dirs=$HOME/.android
      )
    EOS

    (buildpath/"profiles/mistral.sb").write <<~EOS
      ;; Custom sandbox profile: mistral
      ;;
      ;; Re-enables access to things blocked by safehouse defaults:
      ;;   - $HOME/.vibe (read + write)
      ;;
      ;; Activated automatically when using --mistral / vibe-safe

      (version 1)

      (allow file-read* file-write*
        (home-subpath "/.vibe")
      )
    EOS

    (buildpath/"profiles/codex.sb").write <<~EOS
      ;; Custom sandbox profile: codex
      ;;
      ;; Re-enables access to things blocked by safehouse defaults:
      ;;   - $HOME/.codex (read + write)
      ;;
      ;; Activated automatically when using --codex / codex-safe

      (version 1)

      (allow file-read* file-write*
        (home-subpath "/.codex")
      )
    EOS

    (buildpath/"profiles/network-isolation.sb").write <<~EOS
      ;; Network isolation profile
      ;;
      ;; Blocks localhost/loopback traffic.
      ;;
      ;; Re-enable localhost: --allow-localhost=PORTS (selected ports)
      ;;                       --allow-localhost / --enable=localhost (all ports)
      ;;
      ;; NOTE: Private network deny rules use wildcard IP patterns (e.g.
      ;; "10.*:*") whose support in SBPL is undocumented. These rules are
      ;; best-effort — they are harmless if the syntax is unsupported.

      (version 1)

      ;; Block localhost/loopback
      ;;
      ;; SBPL only allows "localhost" or "*" as host in (remote ip) / (local ip)
      ;; filters — literal IPs like "127.0.0.1" are rejected. "localhost" covers
      ;; both IPv4 (127.0.0.1) and IPv6 (::1) loopback.
      (deny network-outbound (remote ip "localhost:*"))
      (deny network-bind     (local ip "localhost:*"))
      (deny network-inbound  (local ip "localhost:*"))

      ;; NOTE: Private network blocking (10.x, 172.16-31.x, 192.168.x) is not
      ;; possible at the SBPL level — the ip filter only accepts "localhost" or
      ;; "*" as host. Blocking private networks would require a proxy layer.
    EOS

    (buildpath/"profiles/vault.sb").write <<~EOS
      ;; Custom sandbox profile: vault
      ;;
      ;; Re-enables access to vault files blocked by
      ;; sandstorm-additional-claude-safe-guards.sb
      ;;
      ;; Activated via: claude-safe --enable=vault

      (version 1)

      (allow file-read* file-write*
        (regex #"/\.vault([^/]*)?$")
        (regex #"/\.vault[^/]*/")
        (regex #"/vault([^/]*)?$")
        (regex #"/vault[^/]*/")
      )
    EOS

    (buildpath/"profiles/sdd.sb").write <<~EOS
      ;; Custom sandbox profile: sdd
      ;;
      ;; Re-enables what the /sdd Claude Code skill needs:
      ;;   - localhost bind/inbound/outbound
      ;;       The /sdd skill runs the `sdd` CLI, which spawns a nested
      ;;       `claude -p` subprocess. Claude Code's own sandbox (enabled in the
      ;;       user's settings) enforces network rules via a localhost proxy +
      ;;       control server that must bind loopback ports. network-isolation.sb
      ;;       denies that, producing "Failed to start server. Is port 0 in use?"
      ;;       and severing the API connection. Re-allowing localhost fixes it.
      ;;   - .git read/write
      ;;       sdd derives repo_id from the git remote and sdd-groom inspects
      ;;       commits; .git is blocked by default.
      ;;
      ;; Activated via: claude-safe --enable=sdd
      ;;
      ;; NOTE: this re-opens ALL of localhost. It is only loaded when --enable=sdd
      ;; is passed, and claude-safe appends it AFTER network-isolation.sb so these
      ;; allows override the localhost denies (SBPL is last-match-wins).

      (version 1)

      (allow network-bind     (local ip "localhost:*"))
      (allow network-inbound  (local ip "localhost:*"))
      (allow network-outbound (remote ip "localhost:*"))

      (allow file-read* file-write*
        (regex #"/\.git/")
      )
    EOS

    (buildpath/"profiles/claude-metrics.sb").write <<~EOS
      ;; Sandbox profile: claude-metrics
      ;;
      ;; Allows the claude-metrics-emit hook (fired from inside the sandbox
      ;; by Claude Code) to reach its config and state directories:
      ;;   - $HOME/.config/claude-metrics/  — nats.conf + nkey seed (read-only)
      ;;   - $HOME/.cache/claude-metrics/   — session timing + statusline debounce (r/w)
      ;;
      ;; Auto-loaded by claude-safe — no --enable flag needed.

      (version 1)

      (allow file-read*
        (home-subpath "/.config/claude-metrics")
      )
      (allow file-read* file-write*
        (home-subpath "/.cache/claude-metrics")
      )
    EOS

    (share/"profiles").install Dir["profiles/*"]

    # Zsh completion for claude-safe
    (buildpath/"_claude-safe").write <<~ZSH
      #compdef claude-safe

      # All features accepted by --enable (custom + safehouse built-in)
      local -a _claude_safe_features=(
        'env:Re-allow .env file access'
        'git:Re-allow .git folder access'
        'flutter:Flutter/Dart toolchain + .git access'
        'mistral:Vibe config (~/.vibe)'
        'codex:Codex config (~/.codex)'
        'vault:Re-allow vault file access'
        'localhost:Re-allow ALL localhost ports'
        'sdd:SDD decision-graph skill (localhost proxy + .git) — needed for /sdd'
        '1password:1Password integration'
        'agent-browser:Agent browser (implies chromium)'
        'browser-native-messaging:Browser native messaging'
        'chromium-full:Full Chromium access (implies headless)'
        'chromium-headless:Headless Chromium'
        'cleanshot:CleanShot access'
        'clipboard:Clipboard access'
        'cloud-credentials:Cloud credential files'
        'cloud-storage:Cloud storage access'
        'docker:Docker commands and socket'
        'electron:Electron apps (implies macos-gui)'
        'keychain:Keychain access'
        'kubectl:Kubernetes CLI'
        'lldb:LLDB debugger (implies process-control)'
        'macos-gui:macOS GUI frameworks'
        'microphone:Microphone access'
        'playwright-chrome:Playwright Chrome (implies chromium)'
        'process-control:Process enumeration/signalling'
        'shell-init:Shell startup file reads'
        'spotlight:Spotlight search'
        'ssh:SSH agent and keys'
        'vscode:VS Code integration'
        'xcode:Xcode developer tools'
        'all-agents:All agent profiles'
        'all-apps:All app profiles'
        'wide-read:Read-only visibility across /'
      )

      # Handle comma-separated --enable values
      _claude_safe_enable() {
        # Get text after last comma (or full text if no comma)
        local prefix="${IPREFIX}"
        local -a already=("${(@s:,:)PREFIX}")
        if (( ${#already} > 1 )); then
          # There are commas — complete after the last one
          local done="${(j:,:)already[1,-2]}"
          IPREFIX="${prefix}${done},"
          PREFIX="${already[-1]}"
        fi
        _describe -t features 'feature' _claude_safe_features
      }

      _arguments -s -S \\
        '(-h --help)'{-h,--help}'[Show help]' \\
        '*--enable=[Enable features]:feature:_claude_safe_enable' \\
        '*--enable[Enable features (space form)]: :_claude_safe_enable' \\
        '--env=-[Pass environment]::env file:_files' \\
        '*--env-pass=[Pass env vars]:variable names: ' \\
        '*--add-dirs-ro=[Read-only paths]:directories:_files -/' \\
        '*--add-dirs=[Read/write paths]:directories:_files -/' \\
        '--workdir=[Working directory]:directory:_files -/' \\
        '*--append-profile=[Additional sandbox profile]:profile:_files -g "*.sb"' \\
        '--trust-workdir-config[Load .safehouse from workdir]' \\
        '--explain[Print effective grants summary]' \\
        '--stdout[Print policy text to stdout]' \\
        '--mistral[Use Vibe/Mistral instead of Claude]' \\
        '--ds4[Use DS4 chat instead of Claude]' \\
        '--ds4-agent[Use the DS4 agent instead of Claude]' \\
        '--allow-localhost=[Whitelist localhost ports (or "all")]:ports: ' \\
        '--allow-localhost[Whitelist ALL localhost ports]' \\
        '(-)--[Stop processing safehouse args]' \\
        '*::: :->cmd_args' && return

      # After --, no completion (claude/vibe handles its own args)
      if [[ "$state" == cmd_args ]]; then
        _default
      fi
    ZSH

    zsh_completion.install "_claude-safe"

    # Zsh completion for vibe-safe (delegates to claude-safe)
    (buildpath/"_vibe-safe").write <<~ZSH
      #compdef vibe-safe
      _claude-safe "$@"
    ZSH

    zsh_completion.install "_vibe-safe"

    # Zsh completion for ds4-safe / ds4-agent-safe (delegate to claude-safe)
    (buildpath/"_ds4-safe").write <<~ZSH
      #compdef ds4-safe
      _claude-safe "$@"
    ZSH

    zsh_completion.install "_ds4-safe"

    (buildpath/"_ds4-agent-safe").write <<~ZSH
      #compdef ds4-agent-safe
      _claude-safe "$@"
    ZSH

    zsh_completion.install "_ds4-agent-safe"

  end

  def caveats
    <<~EOS
      Run the following two commands to enable claude-safe wrapper

        echo 'source "#{share}/aliases.zsh"' >> ~/.zshrc
        source "#{share}/aliases.zsh"

      Zsh completions are installed automatically (restart your shell or run compinit).

      Prerequisites:
        Claude Code:  brew install --cask claude-code
        Vibe/Mistral: brew install mistral-vibe (optional)
        DS4:          see https://dwarfstar.sh (optional, clone + make)

      Available commands:
        claude           → shows a warning (use claude-safe instead)
        claude-safe      → runs Claude inside agent-safehouse sandbox
        claude-unsafe    → runs Claude without sandboxing
        vibe             → shows a warning (use vibe-safe instead)
        vibe-safe        → runs Vibe/Mistral inside agent-safehouse sandbox
        vibe-unsafe      → runs Vibe/Mistral without sandboxing
        codex            → shows a warning (use codex-safe instead)
        codex-safe       → runs Codex inside agent-safehouse sandbox
        codex-unsafe     → runs Codex without sandboxing
        ds4              → shows a warning (use ds4-safe instead)
        ds4-safe         → runs DS4 chat inside agent-safehouse sandbox
        ds4-unsafe       → runs DS4 chat without sandboxing
        ds4-agent        → shows a warning (use ds4-agent-safe instead)
        ds4-agent-safe   → runs the DS4 agent inside agent-safehouse sandbox
        ds4-agent-unsafe → runs the DS4 agent without sandboxing

      DS4 is used from its checkout, not from PATH. If it is not at ~/src/ds4,
      configure it in ~/.zshrc BEFORE the 'source .../aliases.zsh' line:

        export DS4_HOME=~/src/ds4                 # checkout
        export DS4_MODELS=/Volumes/ssd/ds4-models # weights (default: $DS4_HOME/models)
        export DS4_CACHE=~/.ds4                   # config + KV cache

    EOS
  end

  test do
    assert_predicate share/"aliases.zsh", :exist?
    assert_predicate bin/"ds4-safe", :executable?
    assert_predicate bin/"ds4-agent-safe", :executable?
    # DS4 is optional — without a checkout, ds4-safe must fail with a clear hint.
    output = shell_output("DS4_HOME=#{testpath}/nonexistent #{bin}/ds4-safe 2>&1", 1)
    assert_match "DS4 executable not found", output
  end
end
