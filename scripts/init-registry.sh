#!/usr/bin/env bash
# Initialize or update the package registry and context files for an OBS project.
# Discovers all packages, detects ecosystems and upstream sources, generates everything.
#
# Usage: bash init-registry.sh --project <devel-project> --user <obs-user> [--branch <branch-project>]
#        bash init-registry.sh --project systemsmanagement:ansible --user spectro
#
# If --branch is not given, it defaults to home:<user>:branches:<project>
# If a registry already exists, the project is merged into it (existing packages preserved).

set -euo pipefail

PROJECT=""
USER=""
BRANCH=""
REGISTRY="$HOME/.claude/obs-packages.json"
CONTEXT_DIR="$HOME/.claude/obs-packages/context"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --project)  PROJECT="$2"; shift 2 ;;
        --user)     USER="$2"; shift 2 ;;
        --branch)   BRANCH="$2"; shift 2 ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PROJECT" ]; then
    echo "Usage: init-registry.sh --project <devel-project> --user <obs-user>" >&2
    exit 1
fi

# Auto-detect user from osc if not given
if [ -z "$USER" ]; then
    USER=$(osc whois 2>/dev/null | head -1 | awk -F: '{print $1}' | tr -d ' ')
    if [ -z "$USER" ]; then
        echo "Could not detect OBS user. Pass --user <username>" >&2
        exit 1
    fi
    echo "Detected OBS user: $USER" >&2
fi

BRANCH="${BRANCH:-home:${USER}:branches:${PROJECT}}"

mkdir -p "$CONTEXT_DIR"

python3 << PYEOF
import subprocess, re, json, os, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

PROJECT = "$PROJECT"
USER = "$USER"
BRANCH = "$BRANCH"
REGISTRY = "$REGISTRY"
CONTEXT_DIR = "$CONTEXT_DIR"
SCRIPT_DIR = "$SCRIPT_DIR"

def osc_ls(project):
    r = subprocess.run(["osc", "ls", project], capture_output=True, text=True, timeout=15)
    if r.returncode != 0:
        return []
    return [p for p in r.stdout.strip().splitlines() if p and ":" not in p]

def read_spec(project, package):
    r = subprocess.run(
        ["osc", "cat", project, package, f"{package}.spec"],
        capture_output=True, text=True, timeout=20
    )
    return r.stdout if r.returncode == 0 else ""

def detect_ecosystem(spec):
    if "%pyproject_wheel" in spec or "%python_build" in spec: return "python"
    if "%gobuild" in spec or "go build" in spec: return "go"
    if "%cargo_build" in spec: return "rust"
    return "generic"

def detect_upstream(spec, pkg_name, ecosystem):
    source = ""
    m = re.search(r'^Source\d*:\s*(.*)', spec, re.MULTILINE)
    if m: source = m.group(1).strip()

    if ecosystem == "python":
        # Try PyPI name from source URL
        m = re.search(r'pypi\.org/packages/source/\w/([^/]+)', source)
        if m: return {"type": "pypi", "name": m.group(1)}
        # Try GitHub URL
        m = re.search(r'github\.com/[^/]+/([^/]+)', source)
        if m: return {"type": "pypi", "name": m.group(1).rstrip(".git")}
        # Strip python- prefix
        name = pkg_name[7:] if pkg_name.startswith("python-") else pkg_name
        return {"type": "pypi", "name": name}

    elif ecosystem == "go":
        m = re.search(r'github\.com/([^/]+/[^/]+)', source)
        if m: return {"type": "github", "repo": m.group(1).rstrip(".git")}

    elif ecosystem == "rust":
        name = pkg_name[5:] if pkg_name.startswith("rust-") else pkg_name
        return {"type": "crates", "name": name}

    # Generic: try GitHub
    m = re.search(r'github\.com/([^/]+/[^/]+)', source)
    if m: return {"type": "github", "repo": m.group(1).rstrip(".git")}

    return None

def get_version(spec):
    m = re.search(r'^Version:\s*(.*)', spec, re.MULTILINE)
    return m.group(1).strip() if m else ""

def scan_package(pkg_name):
    """Scan a single package from the devel project."""
    spec = read_spec(PROJECT, pkg_name)
    if not spec:
        return None

    ecosystem = detect_ecosystem(spec)
    upstream = detect_upstream(spec, pkg_name, ecosystem)
    version = get_version(spec)

    return {
        "name": pkg_name,
        "ecosystem": ecosystem,
        "obs_version": version,
        "upstream": upstream,
    }

# Discover packages
print(f"Discovering packages in {PROJECT}...", file=sys.stderr)
devel_packages = osc_ls(PROJECT)
print(f"  Found {len(devel_packages)} packages in devel", file=sys.stderr)

# Check which are in the branch
branch_packages = set(osc_ls(BRANCH))
print(f"  Found {len(branch_packages)} packages in branch ({BRANCH})", file=sys.stderr)

# Check which are in user's home project
home_project = f"home:{USER}:ansible-devtools"
home_packages = set(osc_ls(home_project))
alt_home = f"home:{USER}"
if not home_packages:
    home_packages = set(osc_ls(alt_home))
print(f"  Found {len(home_packages)} packages in home project", file=sys.stderr)

# Scan all packages in parallel
print(f"Scanning {len(devel_packages)} packages (detecting ecosystems, upstream sources)...", file=sys.stderr)
results = {}
with ThreadPoolExecutor(max_workers=8) as executor:
    futures = {executor.submit(scan_package, pkg): pkg for pkg in devel_packages}
    done = 0
    for future in as_completed(futures):
        done += 1
        pkg_name = futures[future]
        try:
            result = future.result()
            if result:
                results[pkg_name] = result
                if done % 10 == 0:
                    print(f"  Scanned {done}/{len(devel_packages)}...", file=sys.stderr)
        except Exception as e:
            print(f"  Error scanning {pkg_name}: {e}", file=sys.stderr)

print(f"  Scanned {len(results)} packages successfully", file=sys.stderr)

# Load existing registry or create new
if os.path.exists(REGISTRY):
    with open(REGISTRY) as f:
        registry = json.load(f)
    print(f"Merging into existing registry", file=sys.stderr)
else:
    registry = {
        "maintainer": {
            "obs_user": USER,
            "branch_prefix": f"home:{USER}:branches"
        },
        "projects": {}
    }

# Build project entry
pkg_entries = {}
for pkg_name, info in sorted(results.items()):
    entry = {
        "ecosystem": info["ecosystem"],
        "obs_version": info["obs_version"],
        "in_branch": pkg_name in branch_packages,
        "in_home": pkg_name in home_packages,
    }
    if info["upstream"]:
        entry["upstream"] = info["upstream"]
    pkg_entries[pkg_name] = entry

# Merge: preserve existing package data (known_issues, last_updated, etc.)
if PROJECT in registry.get("projects", {}):
    existing = registry["projects"][PROJECT].get("packages", {})
    for pkg_name, entry in pkg_entries.items():
        if pkg_name in existing:
            # Preserve user-added fields
            for key in ["known_issues", "last_updated", "last_scanned"]:
                if key in existing[pkg_name]:
                    entry[key] = existing[pkg_name][key]
    print(f"  Preserved existing data for {len(existing)} packages", file=sys.stderr)

registry["projects"][PROJECT] = {
    "devel_project": PROJECT,
    "branch_project": BRANCH,
    "target_projects": ["openSUSE:Factory"],
    "packages": pkg_entries,
}

# Write registry
with open(REGISTRY, "w") as f:
    json.dump(registry, f, indent=2)
print(f"Registry written: {REGISTRY} ({len(pkg_entries)} packages)", file=sys.stderr)

# Generate context files for branch packages
branch_with_context = [p for p in branch_packages if p in results]
print(f"Generating context files for {len(branch_with_context)} branch packages...", file=sys.stderr)

for pkg_name in sorted(branch_with_context):
    ctx_path = os.path.join(CONTEXT_DIR, f"{pkg_name}.md")
    if os.path.exists(ctx_path):
        print(f"  Skipping {pkg_name} (context exists)", file=sys.stderr)
        continue
    r = subprocess.run(
        ["bash", os.path.join(SCRIPT_DIR, "generate-context.sh"),
         "--project", PROJECT, "--package", pkg_name,
         "--branch", BRANCH, "--output", ctx_path],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode == 0:
        print(f"  Generated: {pkg_name}", file=sys.stderr)
    else:
        print(f"  Failed: {pkg_name}: {r.stderr[:100]}", file=sys.stderr)

# Output summary JSON
summary = {
    "project": PROJECT,
    "branch": BRANCH,
    "user": USER,
    "total_packages": len(pkg_entries),
    "in_branch": len(branch_packages & set(results.keys())),
    "ecosystems": {},
    "context_files_generated": len(branch_with_context),
}
for entry in pkg_entries.values():
    eco = entry["ecosystem"]
    summary["ecosystems"][eco] = summary["ecosystems"].get(eco, 0) + 1

print(json.dumps(summary, indent=2))
PYEOF
