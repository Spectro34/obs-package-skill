# obs-package-skill — sandbox functionality test

**Run:** 2026-05-11 · sandboxed (worktree + fake `$HOME`) · `claude` 2.1.138 · `osc` configured against build.opensuse.org

A sub-agent exercised every component in isolation; no writes to the user's real `~/.claude/`, no OBS state-changing operations.

## Surfaces tested

| Surface | Coverage |
|---------|----------|
| `hooks/block-osc-sr.sh` | 13 positive blocks + allow-list (8 cases) |
| `hooks/block-secrets.sh` | 24 regression + 5 adversarial inputs |
| `scripts/scan-packages.sh` | flag parsing, registry override, fall-through to Python |
| `scripts/init-registry.sh` | argument parser, `--help` |
| `scripts/generate-context.sh` | argument parser, `--help` |
| `setup.sh` | install into fake `$HOME`, idempotency, placeholder rewrite |
| `settings-example.json`, `registry-example.json`, `mcp-config-example.json` | JSON validity |
| `skill/SKILL.md`, `skill/AGENT.md` | front-matter, structure |
| All `.sh` files | `bash -n` syntax check |

## Issues found and fixed

### HIGH — `block-osc-sr.sh` failed to block direct OBS API request creation
- **File:** `hooks/block-osc-sr.sh:44`
- **Repro:** `echo '{"tool_name":"Bash","tool_input":{"command":"osc api -X POST /request?cmd=submit"}}' | bash hooks/block-osc-sr.sh` → exit 0 (allowed)
- **Cause:** Line 29 normalises the command via `tr '[:upper:]' '[:lower:]'`, but line 44 then matched `(POST|PUT)` against the already-lowercased string. `osc api -X POST .../request` slipped through — a real bypass of the SR guardrail.
- **Fix:** regex lowercased to `(post|put)` and flag widened to `-[xX]`. Now blocks `-X POST`, `-X PUT`, `--method POST`, and uppercase variants; still allows `osc api GET /request`, `osc api -X POST /build/foo`, etc.

### MEDIUM — `scan-packages.sh` silently ignored the `--registry` path
- **File:** `scripts/scan-packages.sh:5,10,17`
- **Repro:** `bash scripts/scan-packages.sh --registry /tmp/custom.json` → set `REGISTRY=--registry` (literal string), failed with "Registry not found at --registry"; even when the bash variable was correct, the Python heredoc read `os.environ.get("REGISTRY", …)` which fell back to `~/.claude/obs-packages.json` because the bash var was never exported.
- **Cause:** Two bugs stacked — usage docs declared `--registry PATH` but implementation was raw `$1`, and the bash variable wasn't exported into the heredoc.
- **Fix:** Replaced the positional with a proper flag parser (mirroring `init-registry.sh`), added `export REGISTRY` before the heredoc.

### LOW — `--help` returned "Unknown arg" on three scripts
- **Files:** `scripts/init-registry.sh:26`, `scripts/scan-packages.sh`, `scripts/generate-context.sh:20`
- **Fix:** Added `-h|--help` cases to each. Output matches `setup.sh`'s style.

## Issues acknowledged, not changed

### `block-osc-sr.sh` / `block-secrets.sh` — obfuscated bypasses
Two adversarial inputs were correctly identified as undetectable via string-matching alone:
- URL-encoded paths in curl args (`%7e/.oscrc`)
- `eval $(echo … | base64 -d)` wrapping a blocked command

These are inherent limitations of static command matching; closing them would require sandboxing or a stricter command grammar, both out of scope. Documented here so future contributors don't think they're missing.

## Verified passing (no changes)

- `block-secrets.sh` — 24/24 regression + 5/5 adversarial pass
- `block-osc-sr.sh` — all `osc sr` / `osc submitrequest` / `osc request create` variants block; allow-list (`osc ls`, `osc results`, `osc co`, `osc request list|accept`) untouched
- `setup.sh` — installs both hooks into fake `$HOME`, second run is idempotent, `/path/to/hooks` placeholder rewritten to actual path
- All JSON config examples valid
- `bash -n` clean on all five `.sh` files
- `SKILL.md` and `AGENT.md` structurally sound

## Post-fix verification

All four fixed surfaces re-tested. `osc api -X POST /request` now blocks (exit 2); `scan-packages.sh --registry $CUSTOM` honoured and Python opens the supplied path; `--help` on all three scripts returns exit 0 with usage text.
