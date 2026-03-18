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
```
