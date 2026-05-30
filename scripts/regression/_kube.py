"""Cluster-side helpers for the regression checker.

Both Octopus instances deploy into the same physical cluster; their namespaces
are distinguished by a `-local-`/`-saas-` segment, so a single kubectl context
reaches everything. These helpers are best-effort: if kubectl/gh is missing or
the cluster is unreachable they return None, letting check.py SKIP the Argo
invariants instead of failing a CI run that has no cluster.
"""
import json
import re
import subprocess

PR_IN_NAME = re.compile(r"pr-?(\d+)")


def _run(cmd):
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if res.returncode != 0:
        return None
    return res.stdout


def argo_applications():
    """[{name, images[]}] for every Argo Application, or None if unreachable."""
    out = _run(["kubectl", "get", "applications", "-n", "argocd", "-o", "json"])
    if out is None:
        return None
    apps = []
    for it in json.loads(out).get("items", []):
        apps.append({
            "name": it["metadata"]["name"],
            "images": it.get("status", {}).get("summary", {}).get("images", []) or [],
        })
    return apps


def preview_namespaces():
    """Names of every namespace containing 'preview', or None if unreachable."""
    out = _run(["kubectl", "get", "ns", "-o",
                "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"])
    if out is None:
        return None
    return [n for n in out.splitlines() if "preview" in n]


def open_pr_numbers():
    """Set of open PR numbers from gh, or None if gh is unavailable."""
    out = _run(["gh", "pr", "list", "--state", "open", "--limit", "200",
                "--json", "number", "-q", ".[].number"])
    if out is None:
        return None
    return {int(n) for n in out.split()}


def pr_number_in(name):
    """The PR number a preview resource encodes (pr-145 / pr145), or None."""
    m = PR_IN_NAME.search(name)
    return int(m.group(1)) if m else None
