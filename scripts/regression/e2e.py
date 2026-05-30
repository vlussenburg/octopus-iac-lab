#!/usr/bin/env python3
"""End-to-end regression driver for the demo lab.

Drives the full build -> deploy -> verify loop and finishes by running the
read-only checker (check.py). It MUTATES shared state (pushes to main, deploys
to Production), so it is meant to be run by a human, not in unattended CI.

Subcommands:
  build-stable          Bump app/index.html title on main, push, wait for the
                        stable image to auto-deploy to every demo Dev on both
                        instances. Prints the resulting 1.1.<run> version.
  deploy-prod VERSION   Deploy stable VERSION to Production/acme-corp for every
                        demo project on both instances; wait; assert Success.
                        (This is the Production coverage the Dev-only loop lacked.)
  decommission          Open an ephemeral preview PR, confirm Argo provisions
                        the app + namespace, close the PR, assert Argo prunes
                        BOTH (the managed-namespace fix). Needs a live cluster.
  check                 Run the read-only checker.
  all                   build-stable -> deploy-prod <that version> -> check.

Requires: git, gh (authenticated), and .env with both instances' creds.
"""
import subprocess
import sys
import time

import _kube as kube
import _octo as octo

MAIN_WORKTREE = octo.repo_root()
APP_INDEX = MAIN_WORKTREE + "/app/index.html"
POLL_SECONDS = 20
DEV_TIMEOUT = 900
TASK_TIMEOUT = 600
# Argo polls GitHub for PR open/close on a 60 s requeue; give creation and
# pruning generous headroom over that.
PREVIEW_TIMEOUT = 600


def sh(cmd, cwd=MAIN_WORKTREE, check=True, capture=False):
    print("$ " + " ".join(cmd))
    res = subprocess.run(cmd, cwd=cwd, check=check,
                         capture_output=capture, text=True)
    return res.stdout.strip() if capture else None


def environments(inst):
    envs = {e["Name"]: e["Id"] for e in inst.api("/environments?take=100")["Items"]}
    return envs


def tenant_id(inst):
    for t in inst.api("/tenants?partialName=" + octo.TENANT)["Items"]:
        if t["Name"] == octo.TENANT:
            return t["Id"]
    return None


def wait_dev(version, instances):
    """Block until every demo project's Dev == version & Success on all instances."""
    deadline = time.time() + DEV_TIMEOUT
    want = set(octo.DEMO_PROJECTS)
    while time.time() < deadline:
        all_ok = True
        snapshot = []
        for inst in instances:
            for pname, env, ver, state in octo.dashboard_rows(inst, want):
                if env != "Dev":
                    continue
                ok = (ver == version and state == "Success")
                all_ok = all_ok and ok
                snapshot.append("  {:5} {:32} {:14} {} {}".format(
                    inst.label, pname, ver, state, "OK" if ok else ""))
        print("--- waiting for Dev == {} ---".format(version))
        print("\n".join(sorted(snapshot)))
        if all_ok:
            print("Dev converged on {}.".format(version))
            return True
        time.sleep(POLL_SECONDS)
    print("TIMEOUT waiting for Dev == {}.".format(version))
    return False


def wait_tasks(inst, task_ids):
    deadline = time.time() + TASK_TIMEOUT
    states = {}
    while time.time() < deadline:
        states = {t: inst.api("/tasks/" + t)["State"] for t in task_ids}
        if all(s in ("Success", "Failed", "Canceled") for s in states.values()):
            break
        time.sleep(POLL_SECONDS)
    return states


def build_stable():
    marker = "regression {}".format(time.strftime("%Y%m%d-%H%M%S"))
    text = open(APP_INDEX).read()
    import re
    new_text, n = re.subn(r"<title>Random Quotes[^<]*</title>",
                          "<title>Random Quotes — {}</title>".format(marker), text, count=1)
    if n != 1:
        raise SystemExit("Could not find the <title> marker in " + APP_INDEX)
    open(APP_INDEX, "w").write(new_text)

    def latest_run():
        out = sh(["gh", "run", "list", "--workflow", "build.yml", "--branch", "main",
                  "--limit", "1", "--json", "databaseId,number", "-q",
                  ".[0].databaseId,.[0].number"], capture=True)
        ids = out.splitlines()
        return (ids[0], ids[1]) if len(ids) == 2 else (None, None)

    before_id, _ = latest_run()
    sh(["git", "add", "app/index.html"])
    sh(["git", "commit", "-m", "Regression: trigger stable build ({})".format(marker)])
    sh(["git", "push", "origin", "main"])

    # Wait for the push's run to register before watching, so we don't latch
    # onto the previous (already-finished) build.
    run_id, run_number = None, None
    for _ in range(30):
        rid, rnum = latest_run()
        if rid and rid != before_id:
            run_id, run_number = rid, rnum
            break
        time.sleep(5)
    if not run_id:
        raise SystemExit("New build.yml run did not appear after push.")
    sh(["gh", "run", "watch", "--exit-status", run_id])
    version = "1.1.{}".format(run_number)
    print("Stable build produced {}".format(version))

    env = octo.load_env()
    if not wait_dev(version, octo.instances(env)):
        raise SystemExit("Dev did not converge on " + version)
    return version


def deploy_prod(version):
    env = octo.load_env()
    failures = []
    for inst in octo.instances(env):
        envs = environments(inst)
        prod = envs.get("Production")
        ten = tenant_id(inst)
        if not prod:
            failures.append("{}: no Production environment".format(inst.label))
            continue
        task_to_proj = {}
        for pname in octo.DEMO_PROJECTS:
            proj = octo.find_project(inst, pname)
            if not proj:
                continue
            rel = octo.find_release(inst, proj["Id"], version)
            if not rel:
                print("  {} {}: no {} release, skipping".format(inst.label, pname, version))
                continue
            body = {"ReleaseId": rel["Id"], "EnvironmentId": prod}
            if ten:
                body["TenantId"] = ten
            dep = inst.api("/deployments", method="POST", body=body)
            task_to_proj[dep["TaskId"]] = pname
            print("  {} {} -> Production {} (task {})".format(inst.label, pname, version, dep["TaskId"]))
        if task_to_proj:
            states = wait_tasks(inst, list(task_to_proj))
            for tid, state in states.items():
                line = "  {} {} Production: {}".format(inst.label, task_to_proj[tid], state)
                print(line)
                if state != "Success":
                    failures.append("{} {} Production deploy {} -> {}".format(
                        inst.label, task_to_proj[tid], version, state))
    if failures:
        print("\nPROD DEPLOY FAILURES:")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nAll Production deploys succeeded.")
    return 0


def _argo_app(pr):
    return "randomquotes-preview-pr-{}".format(pr)


def _argo_ns(pr):
    return "argo-randomquotes-preview-pr-{}".format(pr)


def _wait_argo_preview(pr, want_present, timeout):
    """Poll until the PR's Argo app + namespace are both present/absent.

    want_present=True for provisioning, False for deprovisioning. Returns True
    on convergence, False on timeout.
    """
    app, ns = _argo_app(pr), _argo_ns(pr)
    deadline = time.time() + timeout
    while time.time() < deadline:
        names = kube.argo_app_names()
        ns_here = kube.namespace_exists(ns)
        if names is None or ns_here is None:
            raise SystemExit("cluster/kubectl became unreachable mid-test")
        app_here = app in names
        verb = "present" if want_present else "gone"
        print("--- waiting for preview PR #{} {} --- app={} ns={}".format(
            pr, verb, app_here, ns_here))
        if app_here == want_present and ns_here == want_present:
            return True
        time.sleep(POLL_SECONDS)
    return False


def decommission():
    """Open an ephemeral preview PR, confirm Argo provisions it, close the PR,
    and assert Argo prunes BOTH the Application and its namespace.

    This is the regression for the managed-namespace fix: CreateNamespace=true
    used to leave the namespace as an untracked orphan after prune. With the
    namespace rendered as a tracked chart resource it goes in the finalizer
    cascade, so PR close removes it too.

    Octopus's own on-close teardown is intentionally not asserted here: the
    ephemeral channel has no GitReferenceRules, so Octopus reaps previews on the
    24 h parent-environment timer, not on PR close. The Octopus namespace-
    derivation fix is guarded passively by check.py invariant 5.
    """
    if kube.argo_app_names() is None:
        raise SystemExit("decommission needs a reachable cluster (kubectl) — none found")

    ts = time.strftime("%Y%m%d-%H%M%S")
    branch = "feat/regression-decomm-{}".format(ts)
    wt = "/tmp/decomm-{}".format(ts)
    pr = None
    try:
        sh(["git", "fetch", "origin", "main"])
        sh(["git", "worktree", "add", "-b", branch, wt, "origin/main"])
        index = wt + "/app/index.html"
        text = open(index).read()
        marker = "decomm {}".format(ts)
        import re
        new_text, n = re.subn(r"<title>Random Quotes[^<]*</title>",
                              "<title>Random Quotes — {}</title>".format(marker), text, count=1)
        if n != 1:
            raise SystemExit("Could not find the <title> marker in " + index)
        open(index, "w").write(new_text)
        sh(["git", "add", "app/index.html"], cwd=wt)
        sh(["git", "commit", "-m", "Regression: ephemeral preview decommission ({})".format(ts)], cwd=wt)
        sh(["git", "push", "-u", "origin", branch], cwd=wt)
        pr = sh(["gh", "pr", "create", "--head", branch, "--base", "main",
                 "--title", "Regression: preview decommission {}".format(ts),
                 "--body", "Automated decommission regression. Safe to close."],
                cwd=wt, capture=True)
        pr_num = sh(["gh", "pr", "view", branch, "--json", "number", "-q", ".number"],
                    cwd=wt, capture=True)
        print("Opened PR #{} ({})".format(pr_num, pr))

        if not _wait_argo_preview(pr_num, want_present=True, timeout=PREVIEW_TIMEOUT):
            raise SystemExit("preview PR #{} never provisioned in Argo".format(pr_num))
        print("Preview PR #{} provisioned (app + namespace present).".format(pr_num))

        sh(["gh", "pr", "close", branch], cwd=wt)
        print("Closed PR #{}; waiting for Argo to prune…".format(pr_num))
        if not _wait_argo_preview(pr_num, want_present=False, timeout=PREVIEW_TIMEOUT):
            print("\nDECOMMISSION FAILED: app or namespace survived PR close.")
            return 1
        print("\nPreview PR #{} fully decommissioned (app AND namespace pruned).".format(pr_num))
        return 0
    finally:
        if pr is not None:
            subprocess.run(["gh", "pr", "close", branch], cwd=wt)
        subprocess.run(["git", "worktree", "remove", "--force", wt])
        subprocess.run(["git", "push", "origin", "--delete", branch],
                       cwd=MAIN_WORKTREE)
        subprocess.run(["git", "branch", "-D", branch], cwd=MAIN_WORKTREE)


def run_check():
    return subprocess.call([sys.executable, MAIN_WORKTREE + "/scripts/regression/check.py"])


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    if cmd == "build-stable":
        print(build_stable())
        return 0
    if cmd == "deploy-prod":
        if len(args) < 2:
            raise SystemExit("deploy-prod needs a VERSION, e.g. deploy-prod 1.1.179")
        return deploy_prod(args[1])
    if cmd == "decommission":
        return decommission()
    if cmd == "check":
        return run_check()
    if cmd == "all":
        version = build_stable()
        rc = deploy_prod(version)
        rc |= run_check()
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
