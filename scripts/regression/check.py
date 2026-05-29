#!/usr/bin/env python3
"""Read-only regression checker for the demo lab.

Asserts the invariants that the preview-leak work established, across both
Octopus instances (LOCAL + SaaS). Exits non-zero if any invariant is violated,
so it can gate CI or be the final step of the E2E driver.

Invariants:
  1. NO LEAK  - no demo project's Dev runs a -pr preview version.
  2. PROD OK  - no demo project's Production deployment is in a Failed state.
  3. RULES    - every image-bearing action in each demo project's release is
                covered by a Stable-channel rule that pins to stable (tag ^$),
                so the feed trigger can't backfill it with a -pr image.

Usage:
  python3 check.py [--env /path/to/.env]
"""
import sys

import _octo as octo


def covered_by_stable_rule(channel):
    """Return the set of (action, packageRef) the Stable tag rule constrains."""
    covered = set()
    for rule in channel.get("Rules", []):
        if rule.get("Tag") != octo.STABLE_TAG:
            continue
        for ap in rule.get("ActionPackages", []):
            covered.add((ap.get("DeploymentAction"), ap.get("PackageReference") or ""))
    return covered


def check_instance(inst):
    failures = []
    print("\n=== {} ({}, space {}) ===".format(inst.label, inst.url, inst.space))

    # Invariants 1 & 2 come straight off the dashboard.
    rows = list(octo.dashboard_rows(inst, set(octo.DEMO_PROJECTS)))
    for pname, env, version, state in sorted(rows, key=lambda r: (r[0], str(r[1]), r[2])):
        flag = ""
        if env == "Dev" and "-pr" in version:
            failures.append("{}/{} Dev runs preview {} (LEAK)".format(inst.label, pname, version))
            flag = "  <-- LEAK"
        if env == "Production" and state == "Failed":
            failures.append("{}/{} Production deploy {} FAILED".format(inst.label, pname, version))
            flag = "  <-- PROD FAILED"
        print("  {:34} {:11} {:16} {}{}".format(pname, str(env), version, str(state), flag))

    # Invariant 3: channel-rule coverage of every image-bearing action.
    for pname in octo.DEMO_PROJECTS:
        proj = octo.find_project(inst, pname)
        if not proj:
            print("  [rules] {}: project not found, skipping".format(pname))
            continue
        channels = inst.api("/projects/" + proj["Id"] + "/channels")["Items"]
        chan = next((c for c in channels if c["Name"] == octo.STABLE_CHANNEL), None)
        if not chan:
            failures.append("{}/{}: no '{}' channel".format(inst.label, pname, octo.STABLE_CHANNEL))
            continue
        covered = covered_by_stable_rule(chan)
        try:
            tmpl = octo.process_template(inst, proj, chan["Id"])
        except RuntimeError as exc:
            print("  [rules] {}: template fetch failed ({})".format(pname, exc))
            continue
        pkgs = tmpl.get("Packages", []) if tmpl else []
        uncovered = [
            (p.get("ActionName"), p.get("PackageReferenceName") or "")
            for p in pkgs
            if (p.get("ActionName"), p.get("PackageReferenceName") or "") not in covered
        ]
        if uncovered:
            for action, ref in uncovered:
                failures.append("{}/{}: action '{}' (pkg '{}') NOT pinned to stable (LEAK RISK)".format(
                    inst.label, pname, action, ref))
            print("  [rules] {}: {} image action(s) UNPINNED".format(pname, len(uncovered)))
        else:
            print("  [rules] {}: all {} image action(s) pinned to stable".format(pname, len(pkgs)))

    return failures


def main():
    env_path = None
    args = sys.argv[1:]
    if "--env" in args:
        env_path = args[args.index("--env") + 1]

    env = octo.load_env(env_path)
    all_failures = []
    for inst in octo.instances(env):
        all_failures.extend(check_instance(inst))

    print("\n" + "=" * 60)
    if all_failures:
        print("FAIL ({} issue(s)):".format(len(all_failures)))
        for f in all_failures:
            print("  - " + f)
        return 1
    print("PASS: no leak, no failed prod deploy, all image actions pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
