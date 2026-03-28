# OBS Package Workflow

TRIGGER when: user asks to update/bump/package/build an OBS package, mentions "osc", "obs", "spec file", "changelog", ".changes", "submit request", "version bump", or is working in a directory containing .osc/ metadata or .spec files.
DO NOT TRIGGER when: user is working on ansible playbooks/roles (not packaging), editing n8n workflows, or doing general coding unrelated to OBS.

## Overview

You are an OBS (Open Build Service) package maintainer assistant targeting the openSUSE Build Service (api.opensuse.org). You don't just guide the user — you actively do the work: gather full context, understand the package inside out, make changes, run builds, diagnose failures from build logs, apply fixes, and iterate until the package builds clean. You work like a real package maintainer would.

Use the `osc-mcp` MCP server tools when available, fall back to `osc` CLI via Bash when not.

## Safety Rules — READ FIRST

1. **NEVER open a submit request (SR).** The osc-mcp server does not have an SR creation tool, and you must not attempt to create one via CLI either. When the package is ready for submission, tell the user and let them do it manually.
2. **Only commit to branch projects.** Verify the working project is a branch (typically `home:<user>:branches:*`) before any commit. If the project does not look like a personal branch, STOP and confirm with the user.
3. **Never commit to devel or release projects** like `devel:languages:python`, `SUSE:SLE-*:Update`, `SUSE:SLE-*:GA`, or `openSUSE:Factory`. These are targets, not workspaces.
4. **Commits to branches are autonomous.** Show the diff for transparency but do NOT wait for user confirmation — this is the user's own branch. Commit, then verify via OBS build results. The only gate is the SR (which the user does manually).
5. **Validate before building.** Check that spec file parses and changelog is properly formatted before triggering a build.

## Available osc-mcp Tools

When the `osc-mcp` MCP server is configured, prefer these tools over CLI:

| Tool | Use for |
|------|---------|
| `search_bundle` | Find packages across projects |
| `list_source_files` | Inspect package contents, read spec/changes files (returns content of .spec/.kiwi automatically). Use `filename` param to read a specific file regardless of size |
| `branch_bundle` | Branch a package to user's home project and check it out |
| `checkout_bundle` | Check out a package locally to `/tmp/osc-mcp/<project>/<package>` |
| `run_build` | Local offline build (specify `project_name`, `bundle_name`, optionally `arch`, `distribution`, `vm_type`) |
| `run_services` | Run OBS source services (`download_files`, `obs_scm`, `go_modules`, etc.). Pass `services` list to run specific ones |
| `get_project_meta` | Check project config — repos, architectures, build targets, subprojects. Use `filter` to find specific packages |
| `edit_file` | Modify files in the checkout dir (spec, changes, patches). Requires `directory`, `filename`, `content` (full file content) |
| `delete_files` | Remove files matching glob patterns from checkout |
| `commit` | Commit to OBS with a message. Auto-updates `.changes` when `.spec` is modified |
| `get_build_log` | Read build logs — supports `nr_lines`, `offset`, `match`/`exclude` regex filtering. Use `show_succeeded=true` to read successful builds |
| `list_requests` | View existing SRs — filter by `project`, `package`, `states`, `user` |
| `get_request` | View SR details and full diff |
| `search_packages` | Find built (installable) packages in repos — use `path` for distro, `path_repository` for repo type, `pattern` for name |
| `list_archive_files` | Inspect tarball/archive contents without extracting — check directory structure, file names. Use `depth` and `include`/`exclude` regex |
| `extract_archive_files` | Extract specific files from archives — useful to read upstream pyproject.toml, Makefile, etc. |

If osc-mcp is NOT configured, fall back to `osc` CLI commands via Bash, applying the same safety rules.

---

## Phase 0: Context Gathering

**This is the most important phase.** Before making any changes, build a complete picture of the package. A well-informed maintainer gets it right on the first build. Run as many of these in parallel as possible.

### 0.1 — Locate the package

Use `search_bundle` to find all projects containing this package. Classify each:

| Project pattern | Classification | Can commit? |
|----------------|---------------|-------------|
| `openSUSE:Factory` | Factory target | NEVER |
| `SUSE:SLE-*:Update`, `SUSE:SLE-*:GA` | Release targets | NEVER |
| `devel:*` | Development project (upstream for Factory) | NEVER |
| `home:<user>:branches:*` | Personal branch | YES — this is where we work |
| `home:<user>:*` (not branches) | Home project | Ask user first |

Record: the **devel project** (where the package is maintained), the **branch project** (where we'll work), and the **Factory/target** (where it will eventually land).

### 0.2 — Understand the build targets

Use `get_project_meta` on the branch project (or devel project if no branch yet):

- What **repositories** are configured? (e.g., `openSUSE_Tumbleweed`, `openSUSE_Leap_15.6`, `SLE_15_SP6`)
- What **architectures** per repo? (e.g., `x86_64`, `aarch64`, `ppc64le`)
- Are there **path** elements linking to other repos for dependencies?

This tells you what you're building against and what packages are available as dependencies.

### 0.3 — Check current build status

Use `osc results <project> <package>` via Bash (no MCP equivalent for multi-repo results):

```bash
osc results <project> <package>
```

This shows pass/fail/building/unresolvable per repo+arch. Key things to note:
- Which repos are **currently broken** — you may need to fix these too
- Which repos are **unresolvable** — dependency issues to investigate
- Whether the package is **currently building** — wait or check what changed

### 0.4 — Read all source files

Use `list_source_files` on the branch project. This returns:
- File listing with sizes and MD5 hashes
- **Full content** of `.spec` and `.kiwi` files automatically
- Content of other small files

From the spec file, extract and understand:

**Package identity:**
- `Name:`, `Version:`, `Release:`
- `License:` (SPDX identifier)
- `URL:` (upstream project homepage)

**Source acquisition:**
- `Source:` or `Source0:` — how is the tarball named/fetched?
- Is there a `_service` file? → read it with `list_source_files(filename="_service")` to see how sources are fetched (obs_scm, download_files, tar, recompress)
- What revision/tag is pinned in `_service`?

**Patches — understand every one:**
- List all `PatchN:` entries
- For each patch, understand: what does it fix? Is it SUSE-specific or a backport? Was it submitted upstream? Read the changelog entries that introduced each patch for context
- This is critical for version bumps — you need to know which patches to keep, rebase, or drop

**Dependencies:**
- All `BuildRequires:` — what's needed to build
- All `Requires:` — what's needed at runtime
- Note any macro-based deps (e.g., `%{python_module foo}`) — understand what they expand to

**Build recipe:**
- `%prep` — how are sources unpacked? `%setup` flags? `%autosetup`? `%autopatch`?
- `%build` — what build system? (`%cmake`, `%meson`, `%pyproject_wheel`, `%configure && make`, `cargo build`, `go build`)
- `%install` — how are files installed?
- `%check` — are tests run? What framework? Any tests skipped and why?
- `%files` — what files are packaged? Any `%doc`, `%license`, `%dir` entries?

**Macros and conditionals:**
- Any `%if 0%{?suse_version}` conditionals — what distro-specific behavior exists?
- Any custom macro definitions at the top
- `%{?sle15_python_module_pythons}` or similar — Python version selection

**Subpackages:**
- Any `%package -n <subpkg>` definitions — the package may produce multiple RPMs

### 0.5 — Read the changelog

Use `list_source_files(filename="<pkg>.changes")` to read the full changelog. Understand:
- Who maintains this package? (email in recent entries)
- What was the last update? How long ago?
- What kinds of changes are typical? (version bumps, security fixes, patch additions)
- Any recurring issues mentioned?

### 0.6 — Check for pending submit requests

Use `list_requests` with `project` = the devel project, `package` = the package name:
- Are there open SRs already? Don't duplicate work
- Are there declined SRs? Read them with `get_request` — understand why they were declined to avoid the same mistake
- Are there SRs in review? The package might be in flux

Also check `list_requests` with `project` = `openSUSE:Factory`, `package` = the package name — there may be a pending Factory submission.

### 0.7 — Check upstream state

Determine the upstream source and check for newer versions:

**For Python packages** (Source URL contains `pypi.org` or package starts with `python-`):
```bash
# Check latest version on PyPI
curl -s "https://pypi.org/pypi/<upstream-name>/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Latest:', d['info']['version']); print('Requires:', d['info']['requires_python']); [print(f'  {r}') for r in (d['info']['requires_dist'] or []) if 'extra' not in r]"
```

**For GitHub-hosted sources** (Source URL or _service contains `github.com`):
```bash
# Check latest release
curl -s "https://api.github.com/repos/<owner>/<repo>/releases/latest" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Latest:', d.get('tag_name','')); print('Published:', d.get('published_at',''))"

# Check recent tags if no releases
curl -s "https://api.github.com/repos/<owner>/<repo>/tags?per_page=5" | python3 -c "import sys,json; [print(t['name']) for t in json.load(sys.stdin)]"
```

**For Go packages** (go.mod present in source, or `go_modules` service):
```bash
# Check latest version
curl -s "https://proxy.golang.org/<module>/@latest" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Version'])"
```

Compare with current `Version:` in spec. If upstream is newer, this informs what kind of update is needed.

### 0.8 — Check upstream changes between versions (for version bumps)

If doing a version bump, understand what changed upstream:

**GitHub changelog/releases:**
```bash
# Get release notes for the target version
curl -s "https://api.github.com/repos/<owner>/<repo>/releases/tags/v<new-version>" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('body',''))"
```

**PyPI changelog:** Check the project's PyPI page or GitHub releases.

**What to look for:**
- New dependencies added → need new `BuildRequires:`/`Requires:`
- Dependencies dropped → can remove from spec
- New files installed (new CLI tools, new modules) → update `%files`
- Breaking changes → may need spec adjustments
- Security fixes → note CVE numbers for changelog
- Patches that were merged upstream → drop those patches

### 0.9 — Inspect source archive structure (when relevant)

If the spec has `%setup -q -n <dirname>` and you're changing versions, verify the archive structure:

Use `list_archive_files` on the source tarball with `depth=1` to see the top-level directory name. This prevents `%setup` failures where the extracted directory doesn't match what the spec expects.

### 0.10 — Summarize context before proceeding

Present a brief summary to the user:

```
## Package: <name>
- Current version: X.Y.Z (in branch: <project>)
- Upstream latest: A.B.C
- Build status: [passing/failing across N repos]
- Patches: N patches (list which and why)
- Pending SRs: [none / list them]
- Task: [what the user asked to do]
- Plan: [what you're going to do based on all this context]
```

Wait for user confirmation before proceeding to Phase 1.

---

## Phase 1: Make Changes

Depending on the task:

**Version bump:**
1. Update `Version:` in spec
2. Update `Source:` URL or `_service` revision tag to match new version
3. Reset `Release:` to `0`
4. Run `run_services` to fetch new sources (if `_service` exists)
5. Check if patches still apply:
   - For each patch: was the underlying issue fixed upstream? (check upstream changelog from Phase 0.8)
   - If fixed upstream: remove the patch file, its `PatchN:` header, and its `%patchN` application line
   - If still needed: keep it, but be prepared for fuzz/failure in the build
6. Update `BuildRequires:` based on upstream dependency changes (from Phase 0.8)
7. Update `%files` if new files are installed (from Phase 0.8)
8. If archive structure changed: verify with `list_archive_files` and update `%setup -n`
9. Read upstream `pyproject.toml` / `setup.cfg` / `Makefile` if needed — use `extract_archive_files` to pull it from the new source tarball

**Patch addition:**
1. Add the patch file via `edit_file`
2. Add `PatchN:` in the spec header section (after last existing patch, or after `Source:`)
3. Add `%patchN` (or `%patch -P N`) in `%prep` section after `%setup`
4. If the patch fixes a CVE or bug, note it for the changelog

**Build fix:**
1. First understand what's broken by reading the build log (Phase 2)
2. Apply the fix to the appropriate file
3. Rebuild and verify (Phase 2)

---

## Phase 2: Local Pre-flight Build (Optional)

If `run_build` via osc-mcp is available, or `osc build` via CLI, run a local build first. This catches obvious errors (missing deps, broken patches, spec syntax) without waiting for OBS.

```bash
# Via CLI (works in checked-out package directory):
osc build openSUSE_Tumbleweed x86_64 --no-verify --clean
```

Or via osc-mcp: `run_build(project, bundle, arch="x86_64", distribution="openSUSE_Tumbleweed")`

- If the local build passes: good, proceed to Phase 3 (commit + OBS verification)
- If it fails: diagnose and fix using the diagnosis table below, then retry locally
- If local build is not practical (large package, missing local deps, no VM type configured): **skip directly to Phase 3** — OBS will be the build verification

Local builds are a fast feedback loop but NOT a replacement for OBS-side builds. The OBS build environment may differ (different repos, architectures, dependency resolution).

---

## Phase 3: Commit and OBS Build Verification (The Real Loop)

This is the core of what a package maintainer does. The only way to truly verify a package builds is to **commit to OBS and check the server-side build results**.

```
┌─────────────────────────────────────────────┐
│          VERIFY BRANCH + SHOW DIFF           │
│  Confirm project is home:*:branches:*        │
│  Show diff for transparency (don't wait)     │
└──────────────────┬──────────────────────────┘
                   │
            ┌──────▼──────────────────────────┐
            │  COMMIT TO OBS (branch only)     │
            │  osc ci -m "message"             │
            │  Autonomous — this is our branch │
            └──────────────────┬──────────────┘
                               │
            ┌──────────────────▼──────────────┐
            │  WATCH OBS BUILD RESULTS         │
            │  osc results <prj> <pkg> -w      │
            │  (waits until all repos finish)   │
            └──────────────────┬──────────────┘
                               │
                        ┌──────▼──────┐
                        │ All green?  │
                        └──────┬──────┘
                          yes  │  no
                     ┌─────────┤
                     │         ▼
                     │  ┌─────────────────────────┐
                     │  │   READ OBS BUILD LOG     │
                     │  │   get_build_log(project, │
                     │  │     pkg, repo, arch)     │
                     │  │   for each failed repo   │
                     │  └──────────┬──────────────┘
                     │             │
                     │      ┌──────▼──────┐
                     │      │  DIAGNOSE   │
                     │      └──────┬──────┘
                     │             │
                     │      ┌──────▼──────────────┐
                     │      │     APPLY FIX        │
                     │      └──────┬──────────────┘
                     │             │
                     │      ┌──────▼──────────────┐
                     │      │  RECOMMIT TO OBS     │
                     │      │  (show diff, commit) │
                     │      └──────┬──────────────┘
                     │             │
                     │             ▼
                     │       Watch again (loop)
                     │       Max 5 iterations
                     │
                     ▼
              ┌──────────────────┐
              │  ALL BUILDS PASS │
              │  → Phase 4       │
              └──────────────────┘
```

### Step-by-step:

1. **Verify project** is a personal branch (`home:*:branches:*`) — if not, STOP
2. **Show the diff** of all changed files for transparency — do NOT wait for confirmation, this is the user's branch
3. **Commit** to OBS:
   - Via osc-mcp: `commit(message="...", directory="...")`
   - Via CLI: `osc ci -m "..."`
4. **Watch the build** — wait for all repos to finish:
   ```bash
   osc results <project> <package> -w
   ```
   This blocks until all repos report a final state. Typical wait: 2-15 minutes depending on package size and scheduler load.
5. **Check results**:
   ```bash
   osc results <project> <package>
   ```
   Look for `succeeded`, `failed`, `unresolvable`, or `broken` per repo/arch.
6. **If all succeeded**: done — proceed to Phase 4
7. **If any failed**:
   - Read the OBS build log for each failed repo/arch using `get_build_log` (osc-mcp) or `osc buildlog <repo> <arch>` (CLI)
   - Diagnose using the table below
   - Apply the fix locally
   - Show the diff for transparency, then recommit immediately — this is the user's branch, no confirmation needed for fix iterations
   - Watch again
8. **If `unresolvable`**: dependency issue — the package exists in the spec but not in the repo. Different repos may have different packages available. Use `search_packages` to check.
9. **If some repos pass and others fail**: this is normal — different repos have different packages. A package that builds on Tumbleweed may fail on 15.6 due to missing deps. Read each failure separately.

### Important: `unresolvable` vs `failed` vs `broken`

| Status | Meaning | How to fix |
|--------|---------|------------|
| `succeeded` | Build completed successfully | Nothing to do |
| `failed` | Build ran but a command returned non-zero | Read the build log — the error is in there |
| `unresolvable` | OBS can't satisfy BuildRequires from available repos | Check which dep is missing with `osc buildinfo` or read the unresolvable message. The dep may not exist in that repo. |
| `broken` | Package source is broken (bad spec, link conflict, missing source) | Fix the source-level issue (spec syntax, repair link, run services) |
| `disabled` | Build disabled for this repo/arch | Intentional — ignore unless user asks |
| `excluded` | Package excluded from this repo/arch (ExcludeArch in spec) | Intentional — ignore |
| `blocked` | Waiting for a dependency to build first | Wait — will resolve automatically |
| `scheduled` / `building` | In queue or currently building | Wait |

### Build Failure Diagnosis Table

Read the build log and match against these patterns:

| Log pattern | Diagnosis | Fix |
|-------------|-----------|-----|
| `nothing provides <pkg>` or `unresolvable` | Missing BuildRequires | Use `search_packages(path="openSUSE_Tumbleweed", path_repository="standard", pattern="<pkg>")`. Add to `BuildRequires:`. If not found in any repo, tell the user it needs packaging first. |
| `patch -p1 < ... FAILED` or `Hunk #N FAILED` | Patch no longer applies | Check Phase 0.8 context — was it fixed upstream? If yes, remove patch. If no, read the patch and the changed source to rebase it. |
| `File not found: /usr/lib/...` in `%files` | Installed files changed | Filter build log with `match="^/usr\|^/etc\|^/var"` or `match="Installed .but unpackaged"` to see actual installed files. Update `%files`. |
| `No matching package to install: '%{python}-Foo'` | Macro-expanded dep missing | Expand the macro mentally, then `search_packages` for the actual package name. |
| `SyntaxError` or `ImportError` during `%check` | Tests failing | Read test output. Fix: skip broken tests `-k "not test_name"`, add test deps, or as last resort skip `%check` (ask user). |
| `Permission denied` or `Operation not permitted` | Sandbox restriction | Build chroot has no network, no /home. Fix test setup or skip the offending test. |
| `error: Installed (but unpackaged) file(s) found` | New files not in `%files` | Upstream added files. Add to `%files` explicitly. |
| `%pyproject_wheel` or `%python_build` fails | Wrong Python build system | Use `extract_archive_files` to read `pyproject.toml` from source. Match build-backend to BuildRequires (setuptools, hatchling, flit-core, poetry-core, maturin, etc.). |
| `could not open ... No such file or directory` after `%setup` | Archive directory name mismatch | Use `list_archive_files(depth=1)` on the source tarball. Fix `%setup -q -n <actual-dir-name>`. |
| `RPMLINT warning/error` | Packaging policy issue | Read specific message. Common: missing `%license`, bad permissions, non-PIE binary. Fix per rpmlint guidance. |
| `Bad exit status from /var/tmp/rpm-tmp.*` | Script failure in %prep/%build/%install | Read lines before this error in the log. The actual failure is above — a command returned non-zero. |
| `configure: error: ... not found` | Missing build dependency (autotools) | The `configure` script is telling you exactly what library is needed. Search for the `-devel` package. |
| `CMake Error ... could not find` | Missing build dependency (cmake) | Search for the cmake module package or the `-devel` package that provides the `.cmake` file. |

### Build log reading strategy

1. **First pass**: `get_build_log` with no filters — last 1000 lines for overall result
2. **If the log is huge**: `match="error|Error|FAIL|fatal|unresolvable"` to filter to problems
3. **For dependency issues**: `match="nothing provides|unresolvable|not found"`
4. **For file list issues**: `match="Installed .but unpackaged.|File not found"`
5. **To see installed files**: `match="^/usr|^/etc|^/var"` on the file list section
6. **For earlier build output**: Use `offset=` to page through the log from the start
7. **For test failures**: `match="FAILED|ERROR|assert"` to find failing test names

### Resolving dependencies with search_packages

When a build fails with `nothing provides X`:

1. `search_packages(path="openSUSE_Tumbleweed", path_repository="standard", pattern="X")`
2. If found: add exact package name to `BuildRequires:` and rebuild
3. If NOT found: try `path="openSUSE_Factory"` — might be in a different repo
4. If still not found: search for the `-devel` variant (e.g., `libfoo-devel` for `foo`)
5. If nothing: tell the user this dependency needs to be packaged first

### Max iterations

- Run the build-diagnose-fix loop up to **5 times** autonomously
- After each fix, briefly state what you changed and why before rebuilding
- If still failing after 5 iterations, **stop and present**: what you tried, what's still failing, your best guess at what's needed, and whether it requires human judgment
- Examples needing human judgment: "should we disable this test suite?", "this needs a new dependency packaged first", "this patch needs a manual rebase against new upstream code"

---

## Phase 4: After All Builds Pass — STOP

Only reach this phase when `osc results` shows **all relevant repos succeeded** (repos that are `disabled` or `excluded` are OK to ignore).

Present the final report:

```
## Build Results: <package>
| Repository | Arch | Status |
|------------|------|--------|
| openSUSE_Tumbleweed | x86_64 | succeeded |
| openSUSE_Tumbleweed | i586 | succeeded |
| 15.6 | x86_64 | succeeded |
| ... | ... | ... |

All builds passed. Changes committed to <project>/<package>.
To submit, run: osc sr <project> <package> <target_project>
```

Show the target project (from `_link` file or branch metadata).

**Do NOT attempt to create the SR.**

---

## Changelog Entry Format

Use SUSE `.changes` format:
```
-------------------------------------------------------------------
Day Mon DD HH:MM:SS UTC YYYY - user@email.com

- Description of change (bsc#NNNNN if applicable)
```

Generate the timestamp with: `date -u "+%a %b %d %H:%M:%S UTC %Y"`

Note: the osc-mcp `commit` tool auto-updates `.changes` when `.spec` is modified. If using it, provide the changelog text in the commit message and let it handle the formatting. Don't write to `.changes` manually AND let commit auto-update — that will create duplicate entries.

---

## Detecting osc-mcp Availability

At the start of any invocation:
1. Look for tool names starting with `mcp__osc` in the available tools list
2. If found: use MCP tools (structured output, better error handling)
3. If not found: use `osc` CLI via Bash — check `osc` is installed first
4. Some operations need CLI regardless: `osc results` (no MCP equivalent for multi-repo build status)

---

## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| 401 Unauthorized | osc-mcp can't decode obfuscated credentials | Fall back to osc CLI, or tell user to configure keyring |
| 403 Forbidden | Stale cookie cache | Run `osc -A https://api.opensuse.org api /about` to refresh |
| `unresolvable` in build | Missing dependency in target repo | Use `search_packages` to find it, add to BuildRequires |
| `service run failed` | Source service error (network, tag not found) | Check `_service` file — verify the URL/revision/tag is correct for the new version |
| Timeout on `run_build` | Large package, slow build | Normal for big packages. Wait or suggest user runs `osc build` locally |
| `_link` is broken after branching | Source project changed | Re-branch from the current devel project state |
