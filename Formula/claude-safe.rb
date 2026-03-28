# typed: false
# frozen_string_literal: true

class ClaudeCodeRequirement < Requirement
  fatal true

  satisfy(build_env: false) { which("claude") }

  def message
    "Claude Code is required. Please run `brew install --cask claude-code` first."
  end
end

class VibeRequirement < Requirement
  fatal false

  satisfy(build_env: false) { which("vibe") }

  def message
    "Vibe (Mistral coding CLI) is not installed. To use `vibe-safe`, run `brew install mistral-vibe` first."
  end
end

class ClaudeSafe < Formula
  desc "Claude Code wrapped with agent-safehouse sandboxing"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "2.3.0"

  depends_on :macos
  depends_on "eugene1g/safehouse/agent-safehouse"
  depends_on ClaudeCodeRequirement
  depends_on VibeRequirement => :optional

  def install
    (buildpath/"claude-safe").write <<~EOS
      #!/bin/bash

      # Custom profiles installed alongside this script.
      # Names listed here are mapped to --append-profile=PROFILES_DIR/NAME.sb
      # Everything else is passed through to safehouse as --enable=NAME.
      CUSTOM_PROFILES=(env git flutter mistral)
      PROFILES_DIR="#{share}/profiles"

      usage() {
        cat <<EOF
      Usage: $(basename "$0") [options] [-- claude-args...]
             vibe-safe   [options] [-- vibe-args...]

      WHAT CLAUDE-SAFE DOES
        Runs Claude Code (or Vibe for Mistral Code) inside an agent-safehouse sandbox.
        By default, the agent can ONLY read/write the current directory.

      DEFAULT RESTRICTIONS (Sandstorm policy)
        .env files        blocked (read+write)   re-enable: --enable=env
        .git folder       blocked (read+write)   re-enable: --enable=git
        bw / rbw          blocked (exec+read)    Bitwarden CLIs

      CUSTOM PROFILES (claude-safe specific)
        --enable=env        Re-allow .env file access
        --enable=git        Re-allow .git folder access
        --enable=flutter    Flutter/Dart toolchain + .git access
        --enable=mistral    Vibe config (~/.vibe) — auto-enabled by vibe-safe

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

      EXAMPLES
        claude-safe                           Basic sandboxed Claude
        claude-safe --enable=docker           Allow Docker commands
        claude-safe --enable=docker,env       Docker + .env access
        claude-safe --add-dirs-ro=../shared   Read access to sibling dir
        claude-safe -- --resume               Pass --resume to Claude

      MORE INFO
        safehouse -h          Full safehouse documentation
        claude-unsafe -h      Claude without sandbox

      EOF
      }

      for arg in "$@"; do
        case "$arg" in
          -h|--help) usage; exit 0 ;;
        esac
      done

      # Detect --mistral flag and strip it from the arg list
      cmd="claude"
      _filtered=()
      for arg in "$@"; do
        if [[ "$arg" == "--mistral" ]]; then
          cmd="vibe"
        else
          _filtered+=("$arg")
        fi
      done
      set -- "${_filtered[@]}"

      if [[ "$cmd" == "vibe" ]] && ! command -v vibe &>/dev/null; then
        echo "Error: vibe (Mistral CLI) is not installed. Run: brew install mistral-vibe" >&2
        exit 1
      fi

      if [[ "$cmd" == "vibe" ]]; then
        set -- "--enable=mistral" "$@"
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

      # Pre-process args: expand --enable=a,b and --enable a,b forms.
      expanded=()
      args=("$@")
      i=0
      while [[ $i -lt ${#args[@]} ]]; do
        arg="${args[$i]}"
        if [[ "$arg" == --enable=* ]]; then
          while IFS= read -r -d '' token; do
            expanded+=("$token")
          done < <(_expand_enable "${arg#--enable=}")
        elif [[ "$arg" == "--enable" && $((i+1)) -lt ${#args[@]} ]]; then
          ((i++))
          while IFS= read -r -d '' token; do
            expanded+=("$token")
          done < <(_expand_enable "${args[$i]}")
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

      exec env SAFEHOUSE_WORKDIR=. safehouse --append-profile="#{share}/sandstorm-additional-claude-safe-guards.sb" "${safehouse_args[@]}" -- "$cmd" "${claude_args[@]}"

      EOS

    bin.install "claude-safe"

    (buildpath/"vibe-safe").write <<~EOS
      #!/bin/bash
      exec "#{bin}/claude-safe" --mistral "$@"
    EOS

    bin.install "vibe-safe"

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
    EOS

    share.install "aliases.zsh"

    (buildpath/"sandstorm-additional-claude-safe-guards.sb").write <<~EOS
      ;; safehouse profile with additional restriction for claude
      ;; - deny .env files — reads and writes
      ;; - deny .git - reads and writes
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
        (regex #"/\.env([._][^/]*)?$")
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
      ;; allow OrbStack binary
      ;;
      ;; the actual usage is restricted with --enable=docker (which already supports the OrbStack socket)
      ;; ---------------------------------------------------------------------------

      (allow process-exec* file-read*
        (subpath "/Applications/OrbStack.app/")
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
        (regex #"/.env([._][^/]*)?$")
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

  end

  def caveats
    <<~EOS
      Run the following two commands to enable claude-safe wrapper

        echo 'source "#{share}/aliases.zsh"' >> ~/.zshrc
        source "#{share}/aliases.zsh"

      Zsh completions are installed automatically (restart your shell or run compinit).

      Available commands:
        claude        → shows a warning (use claude-safe instead)
        claude-safe   → runs Claude inside agent-safehouse sandbox
        claude-unsafe → runs Claude without sandboxing
        vibe          → shows a warning (use vibe-safe instead)
        vibe-safe     → runs Vibe/Mistral inside agent-safehouse sandbox
        vibe-unsafe   → runs Vibe/Mistral without sandboxing

    EOS
  end

  test do
    assert_predicate share/"aliases.zsh", :exist?
  end
end
