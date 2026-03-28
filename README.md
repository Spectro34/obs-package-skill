# obs-package-skill

A Claude Code skill and safety hook for Open Build Service (OBS) package maintenance workflows. Designed to work with [osc-mcp](https://github.com/openSUSE/osc-mcp) as the MCP server backend, with automatic fallback to the `osc` CLI.

## What it does

The `/obs-package` skill guides Claude Code through the OBS package update workflow:

1. **Identify** the package and project (auto-detects from `.osc/` metadata)
2. **Inspect** current state (spec file, changelog, source files, pending changes)
3. **Guide** the update (version bumps, patch additions, build fixes)
4. **Build** locally to validate before committing
5. **Commit** to your personal branch after showing the diff and getting your confirmation
6. **Stop** and tell you to submit manually

The skill prefers osc-mcp MCP tools when configured, and falls back to `osc` CLI commands when osc-mcp is not available.

## Guardrails

This project enforces three layers of protection to prevent accidental submit requests or commits to the wrong project:

### Layer 1: MCP Server (hardcoded)

The [osc-mcp](https://github.com/openSUSE/osc-mcp) server exposes 18 tools for OBS interaction. **It does not include a submit request creation tool.** There is no `create_request`, `submit`, or equivalent. Claude literally cannot create an SR through the MCP server — the capability does not exist.

### Layer 2: PreToolUse Hook (enforced)

The `hooks/block-osc-sr.sh` script runs as a Claude Code [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) on every Bash command **before it executes**. It blocks:

| Pattern | What it catches |
|---------|----------------|
| `osc sr` | Standard submit request shorthand |
| `osc submitrequest` | Full submit request command |
| `osc request create` | Generic request creation |
| `osc api -X POST .*/request` | Direct API calls to the request endpoint |

If any of these patterns are detected, the hook exits with code 2 and the command is **killed before execution**. Claude cannot bypass this — the hook runs in the harness, not in the LLM.

### Layer 3: Skill Instructions (advisory)

The SKILL.md file explicitly instructs Claude to:
- Never attempt to create a submit request
- Only commit to personal branch projects (`home:<user>:branches:*`)
- Never commit to devel or release projects
- Always show the diff and get user confirmation before committing
- Stop after committing and tell the user to run `osc sr` manually

This layer is soft (LLM instruction), but backed by the two hard layers above.

### Summary

| Layer | Type | Bypassable? |
|-------|------|-------------|
| osc-mcp server | No SR tool exists | No |
| PreToolUse hook | Blocks SR commands before execution | No |
| Skill instructions | Tells Claude not to try | Soft, but redundant |

## Prerequisites

### 1. osc (required)

The `osc` command-line tool must be installed and configured with credentials for your OBS instance.

```bash
# Install osc
# openSUSE/SUSE:
sudo zypper install osc

# Fedora:
sudo dnf install osc

# pip:
pip install osc
```

Configure credentials:

```bash
# Interactive setup — creates ~/.config/osc/oscrc
osc -A https://api.opensuse.org ls
# Enter your username and password when prompted
```

Verify it works:

```bash
osc api /about
```

**Supported credential managers in oscrc:**
- `PlaintextConfigFileCredentialsManager` — works with both osc and osc-mcp
- `ObfuscatedConfigFileCredentialsManager` — works with osc; osc-mcp may need `--user`/`--password` flags or keyring setup
- Kernel keyring / D-Bus Secret Service — works with both osc and osc-mcp

### 2. osc-mcp (recommended, optional)

The [osc-mcp](https://github.com/openSUSE/osc-mcp) MCP server provides structured tool access to OBS. The skill works without it (falls back to `osc` CLI), but MCP tools give better structured output.

```bash
# Build from source (requires Go 1.24+)
git clone https://github.com/openSUSE/osc-mcp.git
cd osc-mcp
go build -o osc-mcp .

# Verify
./osc-mcp --list-tools
```

### 3. Claude Code

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, desktop app, or IDE extension.

## Installation

### 1. Install the skill

Copy `skill/SKILL.md` to your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills/obs-package
cp skill/SKILL.md ~/.claude/skills/obs-package/SKILL.md
```

### 2. Install the safety hook

Copy the hook script and make it executable:

```bash
mkdir -p ~/.claude/hooks
cp hooks/block-osc-sr.sh ~/.claude/hooks/block-osc-sr.sh
chmod +x ~/.claude/hooks/block-osc-sr.sh
```

Add the PreToolUse hook to your Claude Code settings (`~/.claude/settings.json`). If you already have a `hooks` section, merge the `PreToolUse` entry into it:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/block-osc-sr.sh",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

See `settings-example.json` for a complete example.

### 3. Configure osc-mcp as an MCP server (optional)

Add osc-mcp to your project's `.mcp.json` (or `~/.claude/.mcp.json` for global):

```json
{
  "mcpServers": {
    "osc-mcp": {
      "type": "stdio",
      "command": "/path/to/osc-mcp",
      "args": []
    }
  }
}
```

See `mcp-config-example.json` for a complete example.

**Important:** Do not put credentials in the MCP config file. osc-mcp reads credentials from your `~/.config/osc/oscrc` or system keyring automatically. If you need to pass credentials explicitly (e.g., for a non-default API), use environment variables or a separate config file outside of version control.

### 4. Verify installation

Start a new Claude Code session and check:

```
> osc search ansible-creator
```

The skill should auto-trigger. If osc-mcp is configured, you'll see it use `mcp__osc-mcp__search_bundle`. Otherwise, it falls back to `osc se`.

To verify the hook:

```bash
# This should output "BLOCKED" and exit 2
echo '{"tool_name":"Bash","tool_input":{"command":"osc sr home:user:branches:foo bar baz"}}' \
  | bash ~/.claude/hooks/block-osc-sr.sh
```

## Usage

Once installed, the skill triggers automatically when you work with OBS packages. Examples:

```
> update ansible-creator to the latest version
> check the build log for ansible-core on SLE 15
> bump the version of python-ansible-compat and run a local build
> what's the current state of ansible in my branch project?
```

The skill will:
- Search for the package, show you where it exists
- Identify safe branch projects vs. protected targets
- Walk you through the update step by step
- Build locally to catch errors early
- Show you the diff and ask before committing
- Stop after commit — you create the SR yourself

## Project structure

```
.
├── README.md                  # This file
├── skill/
│   └── SKILL.md               # Claude Code skill definition
├── hooks/
│   └── block-osc-sr.sh        # PreToolUse hook to block submit requests
├── mcp-config-example.json    # Example .mcp.json for osc-mcp setup
└── settings-example.json      # Example Claude Code settings with hook
```

## License

Apache-2.0
