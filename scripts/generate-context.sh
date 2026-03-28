#!/usr/bin/env bash
# Generate a context file for a single OBS package by reading its spec.
#
# Usage: bash generate-context.sh --project <project> --package <name> [--branch <branch-project>] [--output <path>]
# Default output: ~/.claude/obs-packages/context/<package>.md

set -euo pipefail

PROJECT=""
PACKAGE=""
BRANCH=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --project) PROJECT="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --branch)  BRANCH="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PROJECT" ] || [ -z "$PACKAGE" ]; then
    echo "Usage: generate-context.sh --project <project> --package <name> [--branch <branch>] [--output <path>]" >&2
    exit 1
fi

OUTPUT="${OUTPUT:-$HOME/.claude/obs-packages/context/${PACKAGE}.md}"
mkdir -p "$(dirname "$OUTPUT")"

python3 << PYEOF
import subprocess, re, os, sys

PROJECT = "$PROJECT"
PACKAGE = "$PACKAGE"
BRANCH = "$BRANCH"
OUTPUT = "$OUTPUT"

def read_osc(project, package, filename):
    r = subprocess.run(
        ["osc", "cat", project, package, filename],
        capture_output=True, text=True, timeout=20
    )
    return r.stdout if r.returncode == 0 else ""

spec = read_osc(PROJECT, PACKAGE, f"{PACKAGE}.spec")
if not spec:
    print(f"Could not read spec for {PROJECT}/{PACKAGE}", file=sys.stderr)
    sys.exit(1)

svc = read_osc(PROJECT, PACKAGE, "_service")
changes = read_osc(PROJECT, PACKAGE, f"{PACKAGE}.changes")[:3000]

# Extract spec fields
def field(name):
    m = re.search(rf'^{name}:\s*(.*)', spec, re.MULTILINE)
    return m.group(1).strip() if m else ""

version = field("Version")
license_ = field("License")
url = field("URL")
summary = field("Summary")

# Source URL
source_url = ""
m = re.search(r'^Source\d*:\s*(.*)', spec, re.MULTILINE)
if m: source_url = m.group(1).strip()

# Build system
build_system = "unknown"
if "%pyproject_wheel" in spec: build_system = "pyproject"
elif "%python_build" in spec: build_system = "python_build"
elif "%gobuild" in spec: build_system = "go"
elif "%cargo_build" in spec: build_system = "cargo"
elif "%cmake" in spec: build_system = "cmake"
elif "%meson" in spec: build_system = "meson"
elif "%configure" in spec: build_system = "autotools"

# Ecosystem
ecosystem = "generic"
if build_system in ("pyproject", "python_build"): ecosystem = "python"
elif build_system == "go": ecosystem = "go"
elif build_system == "cargo": ecosystem = "rust"

# Source service type
svc_type = "none"
if "obs_scm" in svc: svc_type = "obs_scm"
elif "download_files" in svc: svc_type = "download_files"
elif "tar_scm" in svc: svc_type = "tar_scm"

# Last maintainer from changelog
maintainer = "unknown"
m = re.search(r'UTC \d{4} - (.+?)$', changes, re.MULTILINE)
if m: maintainer = m.group(1)

# Patches
patches = re.findall(r'^(Patch\d+):\s*(.*)', spec, re.MULTILINE)

# BuildRequires (only notable ones — skip boilerplate like fdupes, rpm-macros)
brs = re.findall(r'^BuildRequires:\s*(.*)', spec, re.MULTILINE)
notable_brs = [b for b in brs if not any(skip in b for skip in ["fdupes", "python-rpm-macros", "rpm-macros"])]

# Requires
reqs = re.findall(r'^Requires:\s*(.*)', spec, re.MULTILINE)

# Tests
has_tests = "%check" in spec
skipped_tests = []
if has_tests:
    check_idx = spec.index("%check")
    files_idx = spec.index("%files", check_idx) if "%files" in spec[check_idx:] else len(spec)
    check_section = spec[check_idx:check_idx + (files_idx - check_idx)]
    skipped_tests = re.findall(r'or (test_\w+)', check_section)[:15]

# Write context file
with open(OUTPUT, "w") as f:
    f.write(f"# {PACKAGE}\n\n")
    f.write(f"## Identity\n")
    f.write(f"- **Devel project**: {PROJECT}\n")
    if BRANCH:
        f.write(f"- **Branch**: {BRANCH}\n")
    f.write(f"- **Version**: {version}\n")
    f.write(f"- **License**: {license_}\n")
    f.write(f"- **URL**: {url}\n")
    f.write(f"- **Summary**: {summary}\n")
    f.write(f"- **Ecosystem**: {ecosystem}\n")
    f.write(f"- **Build system**: {build_system}\n")
    f.write(f"- **Source service**: {svc_type}\n")
    f.write(f"- **Last maintainer**: {maintainer}\n")

    if source_url:
        f.write(f"\n## Source\n- `{source_url}`\n")

    f.write(f"\n## Dependencies\n")
    if notable_brs:
        f.write(f"### BuildRequires\n")
        for br in notable_brs:
            f.write(f"- `{br}`\n")
    if reqs:
        f.write(f"### Requires\n")
        for req in reqs:
            f.write(f"- `{req}`\n")

    f.write(f"\n## Patches\n")
    if patches:
        for p in patches:
            f.write(f"- `{p[0]}`: {p[1]}\n")
    else:
        f.write(f"None.\n")

    f.write(f"\n## Testing\n")
    if has_tests:
        f.write(f"Tests run during build.\n")
        if skipped_tests:
            f.write(f"\nSkipped tests:\n")
            for t in skipped_tests:
                f.write(f"- \`{t}\`\n")
    else:
        f.write(f"No test suite in spec.\n")

    f.write(f"\n## Known Issues\n_None recorded yet._\n")
    f.write(f"\n## Build History\n_No history yet._\n")
    f.write(f"\n## Notes\n_No notes yet._\n")

print(f"Generated: {OUTPUT}")
PYEOF
