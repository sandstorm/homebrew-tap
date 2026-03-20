# typed: false
# frozen_string_literal: true

class ClaudeCodeRequirement < Requirement
  fatal true

  satisfy(build_env: false) { which("claude") }

  def message
    "Claude Code is required. Please run `brew install --cask claude-code` first."
  end
end

class ClaudeSafe < Formula
  desc "Claude Code wrapped with agent-safehouse sandboxing"
  homepage "https://github.com/sandstorm/homebrew-tap"
  url "https://github.com/sandstorm/homebrew-tap-placeholder/archive/refs/tags/1.0.0.tar.gz"
  sha256 "bedbe2717586bed363eef050a021b6c5de168ce9228a5ec3529274996d882a95"
  version "2.0.1"

  depends_on :macos
  depends_on "eugene1g/safehouse/agent-safehouse"
  depends_on ClaudeCodeRequirement

  def install
    (buildpath/"claude-safe").write <<~EOS
      #!/bin/bash

      # Custom profiles installed alongside this script.
      # Names listed here are mapped to --append-profile=PROFILES_DIR/NAME.sb
      # Everything else is passed through to safehouse as --enable=NAME.
      CUSTOM_PROFILES=(env)
      PROFILES_DIR="#{share}/profiles"

      usage() {
        cat <<EOF
      Usage: $(basename "$0") [safehouse-args]
            $(basename "$0") [safehouse-args] -- [claude-args]

      This runs: safehouse [safehouse-args] -- claude [claude-args]
      and adds additional default settings.

      # Examples

      * claude-safe --add-dirs-ro=../../Packages
        additional directory claude can read file content from
      * claude-safe --enable=docker
        claude may run docker commands, eg docker ps
      * claude-safe --enable=docker,env
        enable docker and custom env profile
      * claude-safe --enable docker,env
        same as above (space form)

      # Show help for safehouse

      Run: safehouse -h

      ## Show help for claude

      Run: claude-unsafe -h

      EOF
      }

      for arg in "$@"; do
        case "$arg" in
          -h|--help) usage; exit 0 ;;
        esac
      done

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
      exec env SAFEHOUSE_WORKDIR=. safehouse --append-profile="#{share}/sandstorm-additional-claude-safe-guards.sb" "${safehouse_args[@]}" -- claude "${claude_args[@]}"

      EOS

    bin.install "claude-safe"

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

      ;; Block reads (file-read-data + file-read-metadata)
      (deny file-read*
        (regex #"/\.env([._][^/]*)?$")
      )

      ;; Block writes and truncation
      (deny file-write*
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

      ;; Block reads (file-read-data + file-read-metadata)
      (deny file-read*
        (regex #"/\.git/")
      )

      ;; Block writes and truncation
      (deny file-write*
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

      (deny process-exec*
        (regex #"(^|/)bw$")
      )

      (deny file-read*
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

      (deny process-exec*
        (regex #"(^|/)rbw$")
      )

      (deny file-read*
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
      (allow file-read*
        (regex #"/.env([._][^/]*)?$")
      )
      (allow file-write*
        (regex #"/.env([._][^/]*)?$")
      )


    EOS

    (share/"profiles").install Dir["profiles/*"]

  end

  def post_install
    skills = [
      { repo: "mattpocock/skills", ref: "b2039ab896a01ebcc539704f69974f7bcdfb1226", subdir: "tdd" },
    ]

    skills.each do |s|
      owner, reponame = s[:repo].split("/")
      subdir   = s[:subdir]
      skill_name = File.basename(subdir)
      clone_dir  = File.expand_path("~/.claude/.skills/#{owner}-#{reponame}")
      link       = File.expand_path("~/.claude/skills/#{skill_name}")

      FileUtils.mkdir_p(File.dirname(clone_dir))

      if Dir.exist?(File.join(clone_dir, ".git"))
        ohai "Fetching #{s[:repo]} ..."
        system "git", "-C", clone_dir, "fetch", "--all", "--tags", "--quiet"
      else
        ohai "Cloning #{s[:repo]} ..."
        system "git", "clone", "https://github.com/#{s[:repo]}", clone_dir
      end

      system "git", "-C", clone_dir, "checkout", s[:ref], "--quiet"

      target = File.join(clone_dir, subdir)
      unless Dir.exist?(target)
        opoo "Subdir '#{subdir}' not found in #{clone_dir}, skipping."
        next
      end

      FileUtils.mkdir_p(File.expand_path("~/.claude/skills"))
      File.delete(link) if File.symlink?(link)
      File.symlink(target, link)

      sha = `git -C #{clone_dir} rev-parse --short HEAD`.strip
      ohai "#{skill_name} installed: #{link} -> #{target} @ #{sha}"
    end
  end

  def caveats
    <<~EOS
      Run the following two commands to enable claude-safe wrapper

        echo 'source "#{share}/aliases.zsh"' >> ~/.zshrc
        source "#{share}/aliases.zsh"

      Available commands:
        claude       → shows a warning (use claude-safe instead)
        claude-safe  → runs Claude inside agent-safehouse sandbox
        claude-unsafe → runs Claude without sandboxing
    EOS
  end

  test do
    assert_predicate share/"aliases.zsh", :exist?
  end
end
