"""Shared helpers for the demo-lab regression scripts.

Reads credentials from the LOCAL worktree's .env (which holds both the local
and SaaS instance creds) or, failing that, from the process environment. Space
IDs are never hardcoded: each instance's default space is resolved by API.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

# Demo projects whose Dev must stay on stable (no -pr leak) and whose channel
# rules must constrain every image-bearing action.
# The regression auto-deploys these to Production unattended. bg-preview parks a
# manual "Promote to active?" intervention before its prod rollout; e2e.py's
# wait_tasks auto-approves it (approve_gates). servicenow-cr-gate is still
# excluded: its prod path waits on a ServiceNow change-request (automatable later
# via the Playwright + SNOW-REST approval path — deferred).
DEMO_PROJECTS = [
    "blue-green-randomquotes",
    "canary-randomquotes",
    "process-template-randomquotes",
    "platform-hub-opa-randomquotes",
    "smoke-step-template-randomquotes",
    "bg-preview-randomquotes",
    "randomquotes",
]

STABLE_CHANNEL = "Stable"
STABLE_TAG = "^$"  # empty pre-release == stable-only; a package covered by this can't take a -pr image
EPHEMERAL_CHANNEL = "Ephemeral Previews"  # OCL references slug "ephemeral-previews"; must exist on every demo project
TENANT = "acme-corp"
DEMO_SPACE_NAME = "IaC Sandbox"  # same name on both instances; ID differs, so resolve by name


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", ".."))


def load_env(explicit_path=None):
    """Layer the process env over a parsed .env (process env wins)."""
    env = {}
    path = explicit_path or os.path.join(repo_root(), ".env")
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                env[key.strip()] = val.strip().strip('"').strip("'")
    for key in ("OCTOPUS_URL", "OCTOPUS_API_KEY",
                "OCTOPUS_SAAS_INSTANCE_ID", "OCTOPUS_SAAS_API_KEY"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    return env


class Instance:
    def __init__(self, label, url, key):
        self.label = label
        self.url = url.rstrip("/")
        self.key = key
        self._space = None

    def _raw(self, path, method="GET", body=None):
        req = urllib.request.Request(self.url + path, method=method)
        req.add_header("X-Octopus-ApiKey", self.key)
        data = None
        if body is not None:
            req.add_header("Content-Type", "application/json")
            data = json.dumps(body).encode()
        try:
            with urllib.request.urlopen(req, data) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()[:600]
            raise RuntimeError(
                "{} {} on {} {} -> {}".format(self.label, exc.code, method, path, detail)
            ) from None

    @property
    def space(self):
        if self._space is None:
            spaces = self._raw("/api/spaces?take=100")["Items"]
            match = next((s for s in spaces if s.get("Name") == DEMO_SPACE_NAME), None)
            if match is None:
                match = next((s for s in spaces if s.get("IsDefault")), spaces[0])
            self._space = match["Id"]
        return self._space

    def api(self, path, method="GET", body=None):
        return self._raw("/api/" + self.space + path, method=method, body=body)


def instances(env):
    out = []
    if env.get("OCTOPUS_URL") and env.get("OCTOPUS_API_KEY"):
        out.append(Instance("LOCAL", env["OCTOPUS_URL"], env["OCTOPUS_API_KEY"]))
    if env.get("OCTOPUS_SAAS_INSTANCE_ID") and env.get("OCTOPUS_SAAS_API_KEY"):
        out.append(Instance(
            "SAAS",
            "https://{}.octopus.app".format(env["OCTOPUS_SAAS_INSTANCE_ID"]),
            env["OCTOPUS_SAAS_API_KEY"],
        ))
    if not out:
        raise SystemExit("No Octopus credentials found in .env or environment.")
    return out


def find_project(inst, name):
    for proj in inst.api("/projects?partialName=" + urllib.parse.quote(name))["Items"]:
        if proj["Name"] == name:
            return proj
    return None


def git_ref(proj):
    ps = proj.get("PersistenceSettings") or {}
    if ps.get("Type") == "VersionControlled":
        return ps.get("DefaultBranch")
    return None


def process_template(inst, proj, channel_id):
    """Channel-scoped deployment-process template; lists every image-bearing
    action's package. Handles CaC (gitRef) and db-backed projects."""
    pid = proj["Id"]
    ref = git_ref(proj)
    if ref:
        enc = urllib.parse.quote(ref, safe="")
        path = "/projects/{}/{}/deploymentprocesses/template?channel={}".format(pid, enc, channel_id)
    else:
        path = "/projects/{}/deploymentprocesses/template?channel={}".format(pid, channel_id)
    return inst.api(path)


def find_release(inst, pid, version):
    for rel in inst.api("/projects/" + pid + "/releases?take=200")["Items"]:
        if rel["Version"] == version:
            return rel
    return None


def dashboard_rows(inst, project_names):
    """Yield (project, environment, version, state) for the named projects."""
    dash = inst.api("/dashboard")
    projs = {p["Id"]: p["Name"] for p in dash["Projects"]}
    envs = {e["Id"]: e["Name"] for e in dash["Environments"]}
    for item in dash["Items"]:
        pname = projs.get(item["ProjectId"], "")
        if pname in project_names:
            yield (pname,
                   envs.get(item["EnvironmentId"]),
                   str(item.get("ReleaseVersion")),
                   item.get("State"))
