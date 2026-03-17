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
  version "1.2.0"

  depends_on :macos
  depends_on "eugene1g/safehouse/agent-safehouse"
  depends_on ClaudeCodeRequirement

  def install
    (buildpath/"claude-safe").write <<~EOS
      #!/bin/bash
      # Usage: claude-safe [safehouse-args...]
      #        claude-safe [safehouse-args] -- [claude-args...]
      safehouse_args=()
      claude_args=()
      found_sep=false
      for arg in "$@"; do
        if ! $found_sep && [[ "$arg" == "--" ]]; then
          found_sep=true
        elif $found_sep; then
          claude_args+=("$arg")
        else
          safehouse_args+=("$arg")
        fi
      done
      exec env SAFEHOUSE_WORKDIR=. safehouse "${safehouse_args[@]}" -- claude "${claude_args[@]}"
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

    (share/"claude-safe").install "aliases.zsh"
  end

  def caveats
    <<~EOS
      Add this line to your ~/.zshrc:

        source "#{share}/claude-safe/aliases.zsh"

      Then restart your shell or run: source ~/.zshrc

      Available commands:
        claude       → shows a warning (use claude-safe instead)
        claude-safe  → runs Claude inside agent-safehouse sandbox
        claude-unsafe → runs Claude without sandboxing
    EOS
  end

  test do
    assert_predicate share/"claude-safe/aliases.zsh", :exist?
  end
end
