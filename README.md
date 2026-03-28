# obs-package-skill

Claude Code skills for [Open Build Service](https://openbuildservice.org/) package maintenance. Tracks your devel project, finds what needs updating, branches packages, fixes builds, verifies on OBS, and stops before the submit request — you stay in control.

Works with [osc-mcp](https://github.com/openSUSE/osc-mcp) when available, falls back to the `osc` CLI.

## Why use this instead of just asking Claude?

Claude Code can already run `osc` commands. But without these skills, every session starts from zero — Claude doesn't know which packages you maintain, what version they're at, what's upstream, which build failures are expected, or how your project is structured. You end up re-explaining the same context every time.

This skill system gives Claude a **persistent brain for your packages**:

| Without skills | With skills |
|----------------|-------------|
| "What packages do I maintain?" — Claude doesn't know | Registry tracks all 39 packages, their ecosystems, upstream sources |
| "Is ansible-creator up to date?" — Claude has to look it up from scratch | Scanner checks all packages against PyPI/GitHub/crates.io in 30 seconds |
| "Fix the build" — Claude reads the log, guesses at the fix | Diagnosis table maps 12+ common failure patterns to exact fixes |
| Build fails on 15.6 again — "is that expected?" | Known issues persist across sessions — flagged but not alarmed |
| Claude tries `osc sr` to "finish the job" | Three-layer guardrail: MCP server can't, hook blocks it, skill knows not to |
| Works on the devel project directly | Always branches first, commits to your branch, verifies OBS builds |
| Manual version bump: edit spec, edit service, edit changelog, build, check, commit | Automated: reads upstream changelog, updates deps, adjusts patches, commits, watches OBS, iterates on failures |

### Features

- **Fleet scanning** — checks all packages in your devel project against upstream (PyPI, GitHub, Go proxy, crates.io) in parallel. Shows a dashboard with outdated, build failures, broken links, and CVE alerts.
- **CVE monitoring** — queries the [OSV](https://osv.dev/) vulnerability database for each package's current version. If a CVE affects you, it shows which version fixes it.
- **Auto-branching** — if a package needs work and isn't in your branch yet, it branches from devel automatically. That's the OBS workflow — no confirmation needed.
- **Build-diagnose-fix loop** — commits to OBS, watches `osc results -w` until all repos finish, reads build logs for failures, applies fixes (missing deps, patch fuzz, file list mismatches, wrong Python build system, etc.), recommits, and verifies again. Up to 5 iterations before asking for help.
- **Ecosystem awareness** — knows how to package Python (pyproject.toml, setuptools, hatchling, flit), Go (go_modules, vendor), and Rust (cargo-packaging). Detects build system from spec and applies the right patterns.
- **Per-package context** — accumulates knowledge about each package over time: what patches exist and why, which tests are skipped and why, known build issues per repo, co-maintainer info. Context is loaded only when working on that package — doesn't bloat the session.
- **Context engineering** — after working on a package, the agent proposes additions to its knowledge base. You review and accept/reject, like approving PRs for the agent's own memory.
- **Three-layer SR guardrail** — osc-mcp has no SR tool (can't), PreToolUse hook blocks `osc sr` before execution (won't), skill instructions say not to (knows). You create submit requests manually when ready.
- **Autonomous branch commits** — the agent shows diffs for transparency but commits to your branch without waiting. The real verification is OBS build results, not a human reviewing a diff. The only manual gate is the SR.

## Quick Start

### Prerequisites

1. **osc** — installed and configured with credentials
   ```bash
   sudo zypper install osc          # openSUSE/SUSE
   osc -A https://api.opensuse.org ls   # configure credentials
   ```

2. **Claude Code** — [CLI, desktop, or IDE extension](https://docs.anthropic.com/en/docs/claude-code)

3. **osc-mcp** _(optional, recommended)_ — [build from source](https://github.com/openSUSE/osc-mcp)

### One-line setup

```bash
git clone https://github.com/Spectro34/obs-package-skill.git
cd obs-package-skill
bash setup.sh
```

The setup script:
1. Checks prerequisites (`osc` installed and configured)
2. Installs skills, scanner scripts, and safety hook
3. Prompts for your OBS devel project and username
4. Discovers all packages and creates the registry

You can also pass arguments to skip prompts:
```bash
bash setup.sh --project systemsmanagement:ansible --user myuser
bash setup.sh --skip-init   # install skills + hook only, set up packages later
```

### Manual install

If you prefer to do it step by step:

```bash
# Skills + scripts
mkdir -p ~/.claude/skills/obs-package ~/.claude/skills/obs-agent
cp skill/SKILL.md ~/.claude/skills/obs-package/SKILL.md
cp skill/AGENT.md ~/.claude/skills/obs-agent/SKILL.md
cp scripts/*.sh ~/.claude/skills/obs-agent/
chmod +x ~/.claude/skills/obs-agent/*.sh

# Safety hook
mkdir -p ~/.claude/hooks
cp hooks/block-osc-sr.sh ~/.claude/hooks/block-osc-sr.sh
chmod +x ~/.claude/hooks/block-osc-sr.sh

# Add hook to settings (merge if you have existing hooks)
# See settings-example.json for the full format
```

Add to `~/.claude/settings.json`:
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

Initialize the package registry:
```bash
bash ~/.claude/skills/obs-agent/init-registry.sh \
  --project systemsmanagement:ansible \
  --user your-obs-username
```

### Optional: add osc-mcp

Add to your project's `.mcp.json`:
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

Do not put credentials in the MCP config — osc-mcp reads from `~/.config/osc/oscrc` or system keyring automatically.

## Usage

### Scan your packages

```
> scan my packages
```

Shows a dashboard of all packages in the devel project:

```
## Package Dashboard — 2026-03-28
## Devel: systemsmanagement:ansible (39 packages)

### Outdated (2)
| Package         | OBS     | Upstream | Branched? | Action       |
|-----------------|---------|----------|-----------|--------------|
| ansible-creator | 25.12.0 | 26.3.2   | no        | Branch + bump|
| python-libtmux  | 0.54.0  | 0.55.0   | no        | Branch + bump|

### Build Failures (3)
| Package          | TW        | 15.6         | Branched? | Known? |
|------------------|-----------|--------------|-----------|--------|
| molecule-plugins | succeeded | unresolvable | yes       | yes    |
| python-ruamel    | succeeded | failed       | yes       | no     |

### CVE Alerts (0)

### Up to Date (34)
ansible-lint, ansible-navigator, ansible-runner, ...
```

### Work on a package

```
> work on python-ruamel.yaml
```

The agent loads the package's context file, hands off to the worker skill which:
1. Reads the spec, changelog, upstream changes, build logs
2. Diagnoses the failure (e.g., wrong `.dist-info` path on SLE 15)
3. Applies the fix
4. Commits to your branch autonomously
5. Watches `osc results -w` until all 6 repos finish
6. If any fail, reads the log, fixes, recommits — up to 5 times
7. Reports: "All builds passed. Run `osc sr` when ready."

If the package isn't branched yet, it branches from devel first.

### Teach it about expected failures

```
> molecule failing on 15.6 is expected, those repos don't have ansible-navigator
```

Saved to the package's known issues. Future scans show it as "known" instead of "needs attention".

### Review what it learned

```
> review context
```

Shows proposed additions to package knowledge. Accept or reject each one.

### Schedule automatic scans

Claude Code can run prompts on a cron schedule within your session using the `/schedule` skill. The scheduled prompt triggers the obs-agent skill like any normal message — all installed skills are available.

```
> /schedule create --cron "3 8 * * 1" --prompt "obs scan — report outdated packages, CVE alerts, and build failures that aren't known issues. Keep it brief."
```

This fires every Monday at ~8am while your Claude Code session is running. The prompt matches the obs-agent trigger ("obs scan") so the skill handles it with the full dashboard.

Other useful schedules:

```
# Daily CVE + outdated check
> /schedule create --cron "7 7 * * *" --prompt "scan my packages — only report CVE alerts and newly outdated packages, skip build status"

# Durable schedule (survives session restarts, saved to .claude/scheduled_tasks.json)
> /schedule create --cron "3 8 * * 1" --durable --prompt "obs scan — full dashboard"
```

Note: non-durable schedules auto-expire after 7 days and only fire while the REPL is idle (not mid-conversation). Use `--durable` for schedules that should survive across sessions.

Manage schedules:
```
> /schedule list       # see all active schedules
> /schedule delete ID  # remove a schedule
```

## How it works

```
~/.claude/
├── obs-packages.json                    # What you maintain (auto-generated)
├── obs-packages/
│   └── context/                         # Per-package knowledge (grows over time)
│       ├── ansible-creator.md
│       └── molecule.md
├── hooks/
│   └── block-osc-sr.sh                  # Blocks submit requests
└── skills/
    ├── obs-agent/                       # Fleet management
    │   ├── SKILL.md                     # Scan, track, triage, context
    │   ├── scan-packages.sh             # Parallel scanner (OBS + upstream + CVE)
    │   ├── init-registry.sh             # First-run package discovery
    │   └── generate-context.sh          # Per-package context generator
    └── obs-package/                     # Single-package worker
        └── SKILL.md                     # Full workflow: context → fix → build → verify
```

### Workflow

```
"scan packages"  →  obs-agent
                       │
                  scan-packages.sh
                  (checks 39 packages in ~30s)
                       │
                  Dashboard: "3 need attention"
                       │
              "work on python-ruamel.yaml"
                       │
                  Not branched? → osc branch
                       │
                  obs-package skill
                  Phase 0: gather context
                  Phase 1: make changes
                  Phase 2: local pre-flight (optional)
                  Phase 3: commit → osc results -w → diagnose → fix → repeat
                  Phase 4: all green → "run osc sr when ready"
```

## Guardrails

Three independent layers prevent accidental submit requests:

| Layer | Mechanism | Bypassable? |
|-------|-----------|-------------|
| **osc-mcp server** | No SR creation tool exists in the binary | No |
| **PreToolUse hook** | `block-osc-sr.sh` kills `osc sr` commands before execution | No |
| **Skill instructions** | Tells Claude to stop after commit | Soft, but backed by the two hard layers |

Branch commits are autonomous — the agent commits to your branch and verifies via OBS builds. The only manual step is creating the submit request when you're satisfied.

## Credential safety

No credentials are stored in this project. Authentication is handled by:
- `osc` CLI: reads `~/.config/osc/oscrc` (configured during `osc` setup)
- `osc-mcp`: reads from oscrc, kernel keyring, or D-Bus Secret Service
- The `.gitignore` excludes `obs-packages.json` and `obs-packages/` to prevent accidentally committing user-specific data

## Project structure

```
.
├── README.md                    # This file
├── setup.sh                     # One-line setup script
├── skill/
│   ├── SKILL.md                 # Single-package workflow (the worker)
│   └── AGENT.md                 # Fleet management (scan, track, triage)
├── scripts/
│   ├── scan-packages.sh         # Parallel package scanner (OBS + upstream + CVE)
│   ├── init-registry.sh         # First-run: discover all packages, create registry
│   └── generate-context.sh      # Generate context file for one package
├── hooks/
│   └── block-osc-sr.sh          # PreToolUse hook — blocks submit requests
├── registry-example.json        # Example registry template
├── context-example.md           # Example per-package context file
├── mcp-config-example.json      # Example .mcp.json for osc-mcp
├── settings-example.json        # Example Claude Code settings with hook
└── .gitignore                   # Excludes user-specific data
```

## License

Apache-2.0
