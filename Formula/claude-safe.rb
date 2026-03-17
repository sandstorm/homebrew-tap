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
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  version "1.0.0"

  depends_on :macos
  depends_on "eugene1g/safehouse/agent-safehouse"
  depends_on ClaudeCodeRequirement

  def install
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

      claude-safe() {
        SAFEHOUSE_WORKDIR=. safehouse claude "$@"
      }

      claude-unsafe() {
        if [[ -n "$_claude_original" ]]; then
          "$_claude_original" "$@"
        else
          command claude "$@"
        fi
      }
    EOS

    (etc/"claude-safe").install "aliases.zsh"

    # Homebrew requires something in prefix to not consider installation empty
    (prefix/"README").write "claude-safe: Claude Code with agent-safehouse sandboxing\n"
  end

  def caveats
    <<~EOS
      Add this line to your ~/.zshrc:

        source "#{etc}/claude-safe/aliases.zsh"

      Then restart your shell or run: source ~/.zshrc

      Available commands:
        claude       → shows a warning (use claude-safe instead)
        claude-safe  → runs Claude inside agent-safehouse sandbox
        claude-unsafe → runs Claude without sandboxing
    EOS
  end

  test do
    assert_predicate etc/"claude-safe/aliases.zsh", :exist?
  end
end
