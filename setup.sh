#!/usr/bin/env bash
# Quick setup for obs-package-skill.
# Run from the cloned repo directory.
#
# Usage:
#   bash setup.sh                    # interactive — prompts for project + user
#   bash setup.sh --project devel:languages:python --user myuser
#   bash setup.sh --skip-init        # install skills + hook only, no registry setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT=""
USER=""
SKIP_INIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --project)   PROJECT="$2"; shift 2 ;;
        --user)      USER="$2"; shift 2 ;;
        --skip-init) SKIP_INIT=true; shift ;;
        -h|--help)
            echo "Usage: bash setup.sh [--project <devel-project>] [--user <obs-user>] [--skip-init]"
            echo ""
            echo "  --project   OBS devel project to monitor (e.g., systemsmanagement:ansible)"
            echo "  --user      Your OBS username (auto-detected from osc if omitted)"
            echo "  --skip-init Install skills and hook only, skip package discovery"
            exit 0
            ;;
        *) echo "Unknown arg: $1. Use --help for usage." >&2; exit 1 ;;
    esac
done

echo "=== obs-package-skill setup ==="
echo ""

# --- Check prerequisites ---
echo "Checking prerequisites..."

if ! command -v osc &>/dev/null; then
    echo "ERROR: osc not found. Install it first:"
    echo "  sudo zypper install osc     # openSUSE/SUSE"
    echo "  pip install osc             # pip"
    exit 1
fi

if ! osc api /about &>/dev/null; then
    echo "ERROR: osc is not configured. Run:"
    echo "  osc -A https://api.opensuse.org ls"
    echo "and enter your credentials."
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "WARNING: claude command not found. Install Claude Code to use the skills."
    echo "  https://docs.anthropic.com/en/docs/claude-code"
fi

echo "  osc: OK"
echo ""

# --- Install skills ---
echo "Installing skills..."

mkdir -p ~/.claude/skills/obs-package
cp "$SCRIPT_DIR/skill/SKILL.md" ~/.claude/skills/obs-package/SKILL.md
echo "  ~/.claude/skills/obs-package/SKILL.md"

mkdir -p ~/.claude/skills/obs-agent
cp "$SCRIPT_DIR/skill/AGENT.md" ~/.claude/skills/obs-agent/SKILL.md
cp "$SCRIPT_DIR/scripts/scan-packages.sh" ~/.claude/skills/obs-agent/scan-packages.sh
cp "$SCRIPT_DIR/scripts/init-registry.sh" ~/.claude/skills/obs-agent/init-registry.sh
cp "$SCRIPT_DIR/scripts/generate-context.sh" ~/.claude/skills/obs-agent/generate-context.sh
chmod +x ~/.claude/skills/obs-agent/*.sh
echo "  ~/.claude/skills/obs-agent/ (SKILL.md + 3 scripts)"

echo ""

# --- Install hook ---
echo "Installing safety hook..."

mkdir -p ~/.claude/hooks
cp "$SCRIPT_DIR/hooks/block-osc-sr.sh" ~/.claude/hooks/block-osc-sr.sh
chmod +x ~/.claude/hooks/block-osc-sr.sh
echo "  ~/.claude/hooks/block-osc-sr.sh"

# Add hook to settings.json if not already there
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    if grep -q "block-osc-sr" "$SETTINGS" 2>/dev/null; then
        echo "  Hook already in settings.json"
    else
        echo ""
        echo "NOTE: Add the PreToolUse hook to $SETTINGS manually:"
        echo '  See settings-example.json for the format.'
        echo '  The hook must fire on Bash tool calls to block osc sr commands.'
    fi
else
    cp "$SCRIPT_DIR/settings-example.json" "$SETTINGS"
    echo "  Created $SETTINGS with hook config"
fi

echo ""

# --- Initialize registry ---
if [ "$SKIP_INIT" = true ]; then
    echo "Skipping registry setup (--skip-init)."
    echo ""
    echo "To set up later, run:"
    echo "  bash ~/.claude/skills/obs-agent/init-registry.sh --project <devel-project>"
    echo ""
    echo "Done."
    exit 0
fi

# Auto-detect user if not provided
if [ -z "$USER" ]; then
    USER=$(osc whois 2>/dev/null | head -1 | awk -F: '{print $1}' | tr -d ' ' || true)
    if [ -n "$USER" ]; then
        echo "Detected OBS user: $USER"
    fi
fi

# Prompt for project if not provided
if [ -z "$PROJECT" ]; then
    echo ""
    echo "Which OBS devel project do you want to monitor?"
    echo "Examples: systemsmanagement:ansible, devel:languages:python, devel:languages:go"
    echo ""
    read -rp "Devel project: " PROJECT
    if [ -z "$PROJECT" ]; then
        echo "No project given. Skipping registry setup."
        echo "Run later: bash ~/.claude/skills/obs-agent/init-registry.sh --project <project>"
        echo ""
        echo "Done. Skills and hook installed."
        exit 0
    fi
fi

if [ -z "$USER" ]; then
    read -rp "OBS username: " USER
    if [ -z "$USER" ]; then
        echo "ERROR: OBS username required." >&2
        exit 1
    fi
fi

echo ""
echo "Discovering packages in $PROJECT..."
bash ~/.claude/skills/obs-agent/init-registry.sh --project "$PROJECT" --user "$USER"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Installed:"
echo "  Skills:   ~/.claude/skills/obs-package/ + ~/.claude/skills/obs-agent/"
echo "  Hook:     ~/.claude/hooks/block-osc-sr.sh"
echo "  Registry: ~/.claude/obs-packages.json"
echo "  Context:  ~/.claude/obs-packages/context/"
echo ""
echo "Next steps:"
echo "  1. Start Claude Code:  claude"
echo "  2. Scan packages:      'scan my packages'"
echo "  3. Work on a package:  'work on <package-name>'"
echo ""
echo "The agent will branch packages from $PROJECT automatically when they need work."
echo "Submit requests are always manual — run 'osc sr' yourself when ready."
