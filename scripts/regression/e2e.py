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
  decommission          Open an ephemeral preview PR, confirm BOTH Argo and
                        Octopus provision it, close the PR, assert Argo prunes
                        natively and (no native on-close path) the Octopus
                        deprovision API tears its namespace down too. Needs a
                        live cluster + both instances' creds.
  check                 Run the read-only checker.
  all                   build-stable -> deploy-prod <that version> -> check.

Requires: git, gh (authenticated), and .env with both instances' creds.
"""
import re
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
# Octopus's preview is gated on the full build pipeline (image push ->
# create-ephemeral-release -> spin-up runbook), so give provisioning a longer
# window than Argo's branch-only generator.
OCTO_PROVISION_TIMEOUT = 1200
# The project whose ephemeral channel materialises native Octopus previews.
OCTO_PREVIEW_PROJECT = "randomquotes"
# spin-up-preview names the namespace randomquotes-<source>-preview-pr<N>;
# <source> (local|saas) differs per instance, so match the stable head + tail.
OCTO_PREVIEW_NS = re.compile(r"^randomquotes-.+-preview-pr(\d+)$")


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


def _is_proceed_gate(it):
    """A real manual-intervention gate offers a Proceed submit button. Transient
    "wait" interruptions (e.g. Argo CD health) carry an empty form and resolve
    themselves — distinguishing on the form is more reliable than on
    CanTakeResponsibility, which reads false until we're on the responsible
    team."""
    for el in ((it.get("Form") or {}).get("Elements") or []):
        ctrl = el.get("Control") or {}
        if ctrl.get("Type") == "SubmitButtonGroup":
            if any(b.get("Value") == "Proceed" for b in ctrl.get("Buttons", [])):
                return True
    return False


def approve_gates(inst, task_ids):
    """Auto-approve any manual-intervention gate blocking one of task_ids.

    A demo branch (bg-preview) parks a "Promote to active?" manual intervention
    in front of its Production rollout. We submit Proceed so the unattended
    regression can clear it. The server ignores ?regardingDocumentId, so match on
    TaskId; identify the gate by its Proceed button, not CanTakeResponsibility.
    """
    want = set(task_ids)
    for it in inst.api("/interruptions?pendingOnly=true&take=100")["Items"]:
        if it.get("TaskId") in want and it.get("IsPending") and _is_proceed_gate(it):
            if not it.get("HasResponsibility"):
                inst.api("/interruptions/{}/responsible".format(it["Id"]), method="PUT")
            inst.api("/interruptions/{}/submit".format(it["Id"]), method="POST",
                     body={"Instructions": None, "Notes": "regression auto-approve",
                           "Result": "Proceed"})
            print("  [gate] approved interruption {} on {}".format(it["Id"], it["TaskId"]))


def wait_tasks(inst, task_ids):
    deadline = time.time() + TASK_TIMEOUT
    states = {}
    while time.time() < deadline:
        approve_gates(inst, task_ids)
        states = {t: inst.api("/tasks/" + t)["State"] for t in task_ids}
        if all(s in ("Success", "Failed", "Canceled") for s in states.values()):
            break
        time.sleep(POLL_SECONDS)
    return states


def build_stable():
    marker = "regression {}".format(time.strftime("%Y%m%d-%H%M%S"))
    text = open(APP_INDEX).read()
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


def _octo_preview_namespaces(pr):
    """Cluster namespaces Octopus's spin-up runbook created for this PR (one per
    instance), or None if kubectl is unreachable. Excludes Argo's preview ns,
    which has a different shape (argo-…-pr-<N>)."""
    names = kube.preview_namespaces()
    if names is None:
        return None
    return sorted(n for n in names
                  if (m := OCTO_PREVIEW_NS.match(n)) and m.group(1) == str(pr))


def _octo_find_ephemeral_env(inst, pr):
    """Octopus hides ephemeral preview environments from the Environments API —
    they're absent from the list and 404 even on GET-by-id. Resolve the env via
    the preview release instead: the `…-pr<N>` release's deployment carries the
    EnvironmentId. Returns {Id, Name} (Name synthesised, matching the namespace
    `…-preview-pr<N>` shape) or None if the release/deployment isn't there yet."""
    pid = octo.find_project(inst, OCTO_PREVIEW_PROJECT)["Id"]
    rels = inst.api("/projects/{}/releases?take=60".format(pid))["Items"]
    rel = next((r for r in rels if re.search(r"-pr{}\b".format(pr), r["Version"])), None)
    if rel is None:
        return None
    deps = inst.api("/releases/{}/deployments?take=10".format(rel["Id"]))["Items"]
    env_id = next((d["EnvironmentId"] for d in deps), None)
    return {"Id": env_id, "Name": "preview-pr{}".format(pr)} if env_id else None


def _octo_deprovision(inst, proj_id, env):
    """Octopus has no native on-PR-close teardown (verified against the server
    binary: deprovision fires only off the parent env's inactivity timer). Drive
    it the one non-GHA way the API allows — POST the deprovision command, which
    runs the teardown-preview runbook that deletes the namespace."""
    inst.api("/projects/{}/environments/ephemeral/{}/deprovision".format(proj_id, env["Id"]),
             method="POST", body={})


def _wait_octo_envs_present(pr, instances, timeout):
    """Block until every instance has a `preview-pr<N>` ephemeral env and the
    cluster shows at least one matching namespace. Returns {label: env}, or None
    on timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ns = _octo_preview_namespaces(pr)
        if ns is None:
            raise SystemExit("cluster/kubectl became unreachable mid-test")
        found = {i.label: _octo_find_ephemeral_env(i, pr) for i in instances}
        print("--- waiting for octopus preview pr#{} present --- envs={} ns={}".format(
            pr, {k: bool(v) for k, v in found.items()}, ns))
        if all(found.values()) and ns:
            return found
        time.sleep(POLL_SECONDS)
    return None


def _wait_octo_ns_gone(pr, timeout):
    """Block until no Octopus preview namespace survives for this PR."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ns = _octo_preview_namespaces(pr)
        if ns is None:
            raise SystemExit("cluster/kubectl became unreachable mid-test")
        print("--- waiting for octopus preview pr#{} ns gone --- ns={}".format(pr, ns))
        if not ns:
            return True
        time.sleep(POLL_SECONDS)
    return False


def decommission():
    """Open an ephemeral preview PR, confirm BOTH preview systems provision it,
    close the PR, and assert both fully tear down.

    Argo prunes on close natively — that half is the regression for the
    managed-namespace fix: CreateNamespace=true left the namespace as an
    untracked orphan after prune; rendering it as a tracked chart resource puts
    it in the finalizer cascade so PR close removes it too.

    Octopus does NOT prune on close — verified against the server binary: the
    only automatic deprovision trigger is the parent env's inactivity timer
    (now 24 h), there is no PR-close handler, and the channel's GitReference
    rules gate provisioning only. The official on-close path is a GitHub Action,
    which this lab deliberately avoids. So we drive Octopus's teardown the one
    non-GHA way the API allows: POST the deprovision command (runs the
    teardown-preview runbook) and assert its namespace is pruned too.
    """
    if kube.argo_app_names() is None:
        raise SystemExit("decommission needs a reachable cluster (kubectl) — none found")
    instances = octo.instances(octo.load_env())

    ts = time.strftime("%Y%m%d-%H%M%S")
    branch = "feat/regression-decomm-{}".format(ts)
    wt = "/tmp/decomm-{}".format(ts)
    pr = None
    pr_num = None
    try:
        sh(["git", "fetch", "origin", "main"])
        sh(["git", "worktree", "add", "-b", branch, wt, "origin/main"])
        index = wt + "/app/index.html"
        text = open(index).read()
        marker = "decomm {}".format(ts)
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
        print("Preview PR #{} provisioned in Argo (app + namespace present).".format(pr_num))

        octo_envs = _wait_octo_envs_present(pr_num, instances, OCTO_PROVISION_TIMEOUT)
        if octo_envs is None:
            raise SystemExit("preview PR #{} never provisioned in Octopus".format(pr_num))
        print("Preview PR #{} provisioned in Octopus on {}.".format(
            pr_num, ", ".join(octo_envs)))

        sh(["gh", "pr", "close", branch], cwd=wt)
        print("Closed PR #{}; waiting for Argo to prune…".format(pr_num))
        if not _wait_argo_preview(pr_num, want_present=False, timeout=PREVIEW_TIMEOUT):
            print("\nDECOMMISSION FAILED: Argo app or namespace survived PR close.")
            return 1
        print("Argo preview pruned (app + namespace gone).")

        print("Deprovisioning Octopus previews (no native on-close path)…")
        for inst in instances:
            pid = octo.find_project(inst, OCTO_PREVIEW_PROJECT)["Id"]
            env = octo_envs[inst.label]
            _octo_deprovision(inst, pid, env)
            print("  {} deprovision requested for {} (env {})".format(
                inst.label, env["Name"], env["Id"]))
        if not _wait_octo_ns_gone(pr_num, timeout=PREVIEW_TIMEOUT):
            print("\nDECOMMISSION FAILED: Octopus preview namespace survived deprovision.")
            return 1

        print("\nPreview PR #{} fully decommissioned — Argo AND Octopus namespaces pruned.".format(pr_num))
        return 0
    finally:
        if pr is not None:
            subprocess.run(["gh", "pr", "close", branch], cwd=wt)
        if pr_num:
            for inst in instances:
                env = _octo_find_ephemeral_env(inst, pr_num)
                if env:
                    proj = octo.find_project(inst, OCTO_PREVIEW_PROJECT)
                    if proj:
                        try:
                            _octo_deprovision(inst, proj["Id"], env)
                        except Exception as exc:
                            print("  cleanup: {} deprovision failed: {}".format(inst.label, exc))
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
