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
  check                 Run the read-only checker.
  all                   build-stable -> deploy-prod <that version> -> check.

Requires: git, gh (authenticated), and .env with both instances' creds.
"""
import subprocess
import sys
import time

import _octo as octo

MAIN_WORKTREE = octo.repo_root()
APP_INDEX = MAIN_WORKTREE + "/app/index.html"
POLL_SECONDS = 20
DEV_TIMEOUT = 900
TASK_TIMEOUT = 600


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
    sh(["git", "add", "app/index.html"])
    sh(["git", "commit", "-m", "Regression: trigger stable build ({})".format(marker)])
    sh(["git", "push", "origin", "main"])

    sh(["gh", "run", "watch", "--exit-status",
        sh(["gh", "run", "list", "--workflow", "build.yml", "--branch", "main",
            "--limit", "1", "--json", "databaseId", "-q", ".[0].databaseId"], capture=True)])
    run_number = sh(["gh", "run", "list", "--workflow", "build.yml", "--branch", "main",
                     "--limit", "1", "--json", "number", "-q", ".[0].number"], capture=True)
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
