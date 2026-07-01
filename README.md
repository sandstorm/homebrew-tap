# Sandstorm Homebrew Tap

## Quick start

Install formula locally without push to Github.

```bash
# add local dev folder as tap
brew tap sandstorm-dev/tap "$(pwd)"

# remove installation from regular tap
brew uninstall claude-safe

# only committed update are considered by homebrew
git commit -am "..."

# reads latest formulas (also from dev tap)
brew update

# (re)install new version from local formula
brew install sandstorm-dev/tap/claude-safe
brew install sandstorm-dev/tap/claude-metrics
```

## claude-safe

`claude-safe` is a macOS security wrapper for Claude Code (by Sandstorm) that mitigates prompt-injection risks — e.g. an agent being tricked into exfiltrating SSH keys, API keys, or cookies via hidden instructions in read content.
It builds on [Agent Safehouse](https://agent-safehouse.dev/) (using macOS's sandbox-exec), adding stricter defaults: deny-by-default access to .git, .env file and more, plus simplified team-wide usage so no one accidentally runs unsandboxed Claude.

For all details, see this German blog post: [claude-safe: Ein Security Wrapper für Claude Code](https://sandstorm.de/blog/posts/claude-safe).

```bash
# installation
brew update && brew install sandstorm/tap/claude-safe claude-code eugene1g/safehouse/agent-safehouse
echo 'source "/opt/homebrew/opt/claude-safe/share/aliases.zsh"' >> ~/.zshrc

# update
brew update && brew upgrade sandstorm/tap/claude-safe claude-code@latest eugene1g/safehouse/agent-safehouse
```

### `--enable` flags

`claude-safe` blocks several sensitive paths by default (`.env`, `.git`, `.vault`, `~/.kube`, `.ssh`, `.aws`, `secrets/`, `credentials/`, etc.). Some of these can be re-enabled per-run via `--enable=NAME` (comma-separated for multiple). Flags marked "NOT re-enableable" in `claude-safe -h` cannot be lifted this way.

Custom profiles (claude-safe specific):

| Flag | Effect |
|------|--------|
| `--enable=env` | Re-allow `.env` file access |
| `--enable=git` | Re-allow `.git` folder access |
| `--enable=flutter` | Flutter/Dart toolchain + `.git` access |
| `--enable=mistral` | Vibe config (`~/.vibe`) — auto-enabled by `vibe-safe` |
| `--enable=codex` | Codex config (`~/.codex`) — auto-enabled by `codex-safe` |
| `--enable=vault` | Re-allow `.vault` file access |
| `--enable=sdd` | SDD decision-graph skill (required for the `/sdd` skill). Re-allows localhost binding (Claude Code's own nested sandbox proxy needs it) + `.git` access |

Safehouse built-in features (pass-through, comma-separated): `1password`, `agent-browser`, `browser-native-messaging`, `chromium-full`, `chromium-headless`, `cleanshot`, `clipboard`, `cloud-credentials`, `cloud-storage`, `docker`, `electron`, `keychain`, `kubectl`, `lldb`, `macos-gui`, `microphone`, `playwright-chrome`, `process-control`, `shell-init`, `spotlight`, `ssh`, `vscode`, `xcode`, `all-agents`, `all-apps`, `wide-read`.

```bash
claude-safe --enable=docker           # allow Docker commands
claude-safe --enable=docker,env       # Docker + .env access
```

Run `claude-safe -h` for the full, always-current list.
