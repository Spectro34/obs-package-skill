#!/usr/bin/env bash
# Scan all tracked packages: compare OBS versions against upstream,
# check build status, detect broken links. Outputs JSON report.
#
# Usage: bash scan-packages.sh [--registry PATH]
# Default registry: ~/.claude/obs-packages.json

set -euo pipefail

REGISTRY="${1:-$HOME/.claude/obs-packages.json}"

if [ ! -f "$REGISTRY" ]; then
    echo '{"error": "Registry not found at '"$REGISTRY"'"}' >&2
    exit 1
fi

python3 << 'PYEOF'
import json, subprocess, sys, os, re
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

REGISTRY_PATH = os.environ.get("REGISTRY", os.path.expanduser("~/.claude/obs-packages.json"))

def load_registry():
    with open(REGISTRY_PATH) as f:
        return json.load(f)

def get_upstream_version(upstream_info):
    """Check upstream for latest version."""
    if not upstream_info:
        return None
    utype = upstream_info.get("type")
    name = upstream_info.get("name", "")
    repo = upstream_info.get("repo", "")
    module = upstream_info.get("module", "")

    try:
        if utype == "pypi":
            r = subprocess.run(
                ["curl", "-sf", f"https://pypi.org/pypi/{name}/json"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                data = json.loads(r.stdout)
                return data["info"]["version"]

        elif utype == "github":
            r = subprocess.run(
                ["curl", "-sf", f"https://api.github.com/repos/{repo}/releases/latest"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                data = json.loads(r.stdout)
                tag = data.get("tag_name", "")
                return re.sub(r'^v', '', tag)

        elif utype == "go":
            r = subprocess.run(
                ["curl", "-sf", f"https://proxy.golang.org/{module}/@latest"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                data = json.loads(r.stdout)
                return re.sub(r'^v', '', data.get("Version", ""))

        elif utype == "crates":
            r = subprocess.run(
                ["curl", "-sf", f"https://crates.io/api/v1/crates/{name}"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                data = json.loads(r.stdout)
                return data["crate"]["newest_version"]
    except:
        pass
    return None

def get_obs_version(project, package):
    """Get current version from OBS spec file."""
    try:
        r = subprocess.run(
            ["osc", "cat", project, package, f"{package}.spec"],
            capture_output=True, text=True, timeout=15
        )
        for line in r.stdout.splitlines():
            m = re.match(r'^Version:\s*(.*)', line)
            if m:
                return m.group(1).strip()
    except:
        pass
    return None

def get_build_results(project, package):
    """Get build status per repo/arch."""
    try:
        r = subprocess.run(
            ["osc", "results", project, package],
            capture_output=True, text=True, timeout=15
        )
        results = {}
        for line in r.stdout.strip().splitlines():
            parts = line.split()
            if len(parts) >= 4:
                repo, arch, status = parts[0], parts[1], parts[3]
                results[f"{repo}/{arch}"] = status
        return results
    except:
        pass
    return {}

def check_link_status(project, package):
    """Check if the package has a broken _link."""
    try:
        r = subprocess.run(
            ["osc", "ls", "-l", project, package],
            capture_output=True, text=True, timeout=15
        )
        if "conflict" in r.stderr.lower() or "conflict" in r.stdout.lower():
            return "broken"
        if "_link" in r.stdout:
            return "linked"
        return "standalone"
    except:
        return "unknown"

def scan_package(project_name, pkg_name, pkg_info):
    """Scan a single package. Returns enriched info."""
    result = {
        "package": pkg_name,
        "ecosystem": pkg_info.get("ecosystem", "generic"),
        "known_issues": pkg_info.get("known_issues", []),
    }

    # Get current OBS version from devel
    obs_ver = get_obs_version(project_name, pkg_name)
    result["obs_version"] = obs_ver

    # Get upstream version
    upstream_ver = get_upstream_version(pkg_info.get("upstream"))
    result["upstream_version"] = upstream_ver

    # Compare
    if obs_ver and upstream_ver:
        result["up_to_date"] = (obs_ver == upstream_ver)
    else:
        result["up_to_date"] = None

    # Build status in devel
    result["devel_build"] = get_build_results(project_name, pkg_name)

    # If package is in a branch, check branch too
    branch_project = None
    if pkg_info.get("in_branch"):
        # We'll get the branch project from the parent call
        result["has_branch"] = True
    else:
        result["has_branch"] = False

    return result

# Main
registry = load_registry()
report = {
    "scan_time": datetime.now(timezone.utc).isoformat(),
    "outdated": [],
    "build_failures": [],
    "broken_links": [],
    "up_to_date": [],
}

for proj_name, proj_info in registry.get("projects", {}).items():
    branch_proj = proj_info.get("branch_project", "")
    packages = proj_info.get("packages", {})

    # Scan all packages in parallel
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {}
        for pkg_name, pkg_info in packages.items():
            f = executor.submit(scan_package, proj_name, pkg_name, pkg_info)
            futures[f] = (pkg_name, pkg_info)

        for future in as_completed(futures):
            pkg_name, pkg_info = futures[future]
            try:
                result = future.result()
                result["project"] = proj_name
                result["branch_project"] = branch_proj

                # Check branch link status
                if result["has_branch"] and branch_proj:
                    link_status = check_link_status(branch_proj, pkg_name)
                    result["branch_link"] = link_status
                    if link_status == "broken":
                        report["broken_links"].append(result)
                        continue

                # Classify
                if result.get("up_to_date") == False:
                    report["outdated"].append(result)
                else:
                    # Check for build failures
                    failures = {k: v for k, v in result.get("devel_build", {}).items()
                               if v in ("failed", "unresolvable", "broken")}
                    if failures:
                        result["failed_repos"] = failures
                        report["build_failures"].append(result)
                    else:
                        report["up_to_date"].append(result)
            except Exception as e:
                report.setdefault("errors", []).append({"package": pkg_name, "error": str(e)})

# Sort by priority
report["outdated"].sort(key=lambda x: x["package"])
report["build_failures"].sort(key=lambda x: x["package"])
report["up_to_date"].sort(key=lambda x: x["package"])

print(json.dumps(report, indent=2))
PYEOF
