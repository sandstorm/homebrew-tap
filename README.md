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
| `--enable=intellij` | JetBrains IDE integration (Claude Code plugin). Whitelists **only** the IDE's WebSocket port on loopback and passes the plugin's env vars through — see [IntelliJ / JetBrains](#intellij--jetbrains) |

Safehouse built-in features (pass-through, comma-separated): `1password`, `agent-browser`, `browser-native-messaging`, `chromium-full`, `chromium-headless`, `cleanshot`, `clipboard`, `cloud-credentials`, `cloud-storage`, `docker`, `electron`, `keychain`, `kubectl`, `lldb`, `macos-gui`, `microphone`, `playwright-chrome`, `process-control`, `shell-init`, `spotlight`, `ssh`, `vscode`, `xcode`, `all-agents`, `all-apps`, `wide-read`.

```bash
claude-safe --enable=docker           # allow Docker commands
claude-safe --enable=docker,env       # Docker + .env access
```

Run `claude-safe -h` for the full, always-current list.

### IntelliJ / JetBrains

The Claude Code JetBrains plugin talks to the CLI over a WebSocket on a random loopback port
(advertised via `~/.claude/ide/<port>.lock` and `CLAUDE_CODE_SSE_PORT`). `claude-safe` denies all
loopback traffic by default, so that connection fails with `EPERM`. Claude still works in the IDE
terminal, but the plugin reports **"Claude failed to start"** and every IDE-side feature stays
dead — native diff viewer, selection sharing, `/ide`.

Fix: launch Claude with `--enable=intellij`, which whitelists only the port the IDE is listening
on and forwards the plugin's env vars into the sandbox.

Point the plugin at a wrapper instead of the bare CLI (Settings → Tools → Claude Code → CLI path,
or the plugin's "Claude command"):

```bash
# ~/.local/bin/claude-safe-intellij
#!/bin/bash
exec claude-safe --enable=intellij "$@"
```

```bash
chmod +x ~/.local/bin/claude-safe-intellij
```

Port discovery needs the IDE to be up first: open the project in IntelliJ with the plugin active,
then start Claude. If the plugin's port cannot be found, `claude-safe` prints a warning and leaves
loopback closed instead of silently widening the sandbox.
