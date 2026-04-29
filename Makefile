# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml
SPACE_DIR := tofu/space
CP_DIR := tofu/control-plane
PH_DIR := tofu/platform-hub
APP_DIR := tofu/app-randomquotes
AGENT_DIR := tofu/k8s-agent

# Load .env (secrets + per-target URL/key) and export TF_VAR_* for OpenTofu.
# Non-sensitive values come from each stack's committed defaults.auto.tfvars.
# OCTOPUS_URL is per-worktree: local has http://localhost:8090, SaaS has the
# https://<id>.octopus.app URL.
define load_env
	set -a; \
	[ -f .env ] || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }; \
	source .env; set +a; \
	[ -n "$$OCTOPUS_URL" ] || { echo "OCTOPUS_URL is unset in .env (e.g. http://localhost:8090 or https://<id>.octopus.app)"; exit 1; }; \
	case "$$OCTOPUS_URL" in *octopus.app*) target=saas ;; *) target=local ;; esac; \
	export TF_VAR_octopus_url="$$OCTOPUS_URL" \
	       TF_VAR_octopus_api_key="$$OCTOPUS_API_KEY" \
	       TF_VAR_github_pat="$$GITHUB_PAT" \
	       TF_VAR_octopus_url_from_cluster="$${OCTOPUS_URL_FROM_CLUSTER:-http://host.docker.internal:8090}" \
	       TF_VAR_octopus_polling_url_from_cluster="$${OCTOPUS_POLLING_URL_FROM_CLUSTER:-https://host.docker.internal:10943}" \
	       TF_VAR_enable_platform_hub="$${OCTOPUS_PLATFORM_HUB_ENABLED:-true}" \
	       TF_VAR_agent_target_name="$${OCTOPUS_AGENT_TARGET_NAME:-octopus-tentacle-$$target}";
endef

.PHONY: help \
        up down logs ps nuke \
        master-key mint-api-key reset \
        space-init space-plan space-apply space-destroy space-fmt space-validate \
        cp-init cp-plan cp-apply cp-destroy cp-fmt cp-validate \
        ph-init ph-plan ph-apply ph-destroy ph-fmt ph-validate \
        app-init app-plan app-apply app-destroy app-fmt app-validate \
        agent-init agent-plan agent-apply agent-destroy agent-fmt agent-validate \
        fmt validate apply destroy

help:
	@echo "compose/              : up | down | logs | ps | nuke      (local self-host only)"
	@echo "bootstrap             : master-key (first-time) | mint-api-key | reset (full rebuild)"
	@echo "tofu/space/           : space-init | space-plan | space-apply | space-destroy | space-fmt | space-validate"
	@echo "tofu/control-plane/   : cp-init | cp-plan | cp-apply | cp-destroy | cp-fmt | cp-validate"
	@echo "tofu/platform-hub/    : ph-init | ph-plan | ph-apply | ph-destroy | ph-fmt | ph-validate"
	@echo "tofu/app-randomquotes/: app-init | app-plan | app-apply | app-destroy | app-fmt | app-validate"
	@echo "tofu/k8s-agent/       : agent-init | agent-plan | agent-apply | agent-destroy | agent-fmt | agent-validate"
	@echo "convenience           : fmt (all) | validate (all) | apply (space,cp,ph,app,agent) | destroy (rev)"

# --- compose/ -------------------------------------------------------------

# If compose/license.xml exists, base64-encode it and pass through as
# OCTOPUS_SERVER_BASE64_LICENSE — install.sh in the Octopus image picks it up
# and applies the licence on boot. Otherwise the licence step is skipped and
# you can paste one in the UI.
up:
	@if [ -f compose/license.xml ]; then \
		export OCTOPUS_SERVER_BASE64_LICENSE=$$(base64 -i compose/license.xml | tr -d '\n'); \
		echo "Loading licence from compose/license.xml"; \
		$(COMPOSE) up -d; \
	else \
		echo "No compose/license.xml — booting without a licence"; \
		$(COMPOSE) up -d; \
	fi

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f octopus

ps:
	$(COMPOSE) ps

nuke:
	@read -p "This deletes the local Octopus DB. Continue? [y/N] " ans && [ "$$ans" = "y" ] || [ "$$ans" = "yes" ]
	$(COMPOSE) down -v --remove-orphans

# --- tofu/space/ ----------------------------------------------------------

space-init:
	cd $(SPACE_DIR) && tofu init

space-plan:
	$(load_env) cd $(SPACE_DIR) && tofu plan

space-apply:
	$(load_env) cd $(SPACE_DIR) && tofu apply

space-destroy:
	$(load_env) cd $(SPACE_DIR) && tofu destroy

space-fmt:
	cd $(SPACE_DIR) && tofu fmt -recursive

space-validate:
	cd $(SPACE_DIR) && tofu validate

# --- tofu/control-plane/ --------------------------------------------------

cp-init:
	cd $(CP_DIR) && tofu init

cp-plan:
	$(load_env) cd $(CP_DIR) && tofu plan

cp-apply:
	$(load_env) cd $(CP_DIR) && tofu apply

cp-destroy:
	$(load_env) cd $(CP_DIR) && tofu destroy

cp-fmt:
	cd $(CP_DIR) && tofu fmt -recursive

cp-validate:
	cd $(CP_DIR) && tofu validate

# --- tofu/platform-hub/ ---------------------------------------------------

ph-init:
	cd $(PH_DIR) && tofu init

ph-plan:
	$(load_env) cd $(PH_DIR) && tofu plan

ph-apply:
	$(load_env) cd $(PH_DIR) && tofu apply

ph-destroy:
	$(load_env) cd $(PH_DIR) && tofu destroy

ph-fmt:
	cd $(PH_DIR) && tofu fmt -recursive

ph-validate:
	cd $(PH_DIR) && tofu validate

# --- tofu/app-randomquotes/ -----------------------------------------------

app-init:
	cd $(APP_DIR) && tofu init

app-plan:
	$(load_env) cd $(APP_DIR) && tofu plan

app-apply:
	$(load_env) cd $(APP_DIR) && tofu apply

app-destroy:
	$(load_env) cd $(APP_DIR) && tofu destroy

app-fmt:
	cd $(APP_DIR) && tofu fmt -recursive

app-validate:
	cd $(APP_DIR) && tofu validate

# --- tofu/k8s-agent/ ------------------------------------------------------

agent-init:
	cd $(AGENT_DIR) && tofu init

agent-plan:
	$(load_env) cd $(AGENT_DIR) && tofu plan

agent-apply:
	$(load_env) cd $(AGENT_DIR) && tofu apply

agent-destroy:
	$(load_env) cd $(AGENT_DIR) && tofu destroy

agent-fmt:
	cd $(AGENT_DIR) && tofu fmt -recursive

agent-validate:
	cd $(AGENT_DIR) && tofu validate

# --- convenience ----------------------------------------------------------

fmt: space-fmt cp-fmt ph-fmt app-fmt agent-fmt
validate: space-validate cp-validate ph-validate app-validate agent-validate

# Apply order: space → cp → ph → app → agent. Every downstream stack reads
# space_id from tofu/space/ via terraform_remote_state, so space must apply
# first. App reads cp outputs too.
apply: space-apply cp-apply ph-apply app-apply agent-apply

# Destroy in reverse — agent first, space last. Destroying space cascades on
# the Octopus side (deleting the Space removes all child resources), but the
# *terraform state* of downstream stacks still references those resources, so
# we destroy them in dependency order to keep state coherent.
destroy: agent-destroy app-destroy ph-destroy cp-destroy space-destroy

# --- bootstrap helpers ----------------------------------------------------

# Generate a fresh 32-byte MASTER_KEY into .env. First-time setup only —
# refuses to overwrite an existing key (would orphan any data encrypted with
# the old one). Run `make reset` if you really want a clean slate.
master-key:
	@CURRENT=$$(grep '^MASTER_KEY=' .env 2>/dev/null | cut -d= -f2-); \
	if [ -n "$$CURRENT" ] && [ "$$CURRENT" != "CHANGE_ME" ]; then \
		echo "MASTER_KEY already set in .env. Refusing to overwrite — run 'make reset' for a clean slate."; \
		exit 1; \
	fi; \
	KEY=$$(openssl rand -base64 32); \
	if grep -q '^MASTER_KEY=' .env 2>/dev/null; then \
		sed -i '' "s|^MASTER_KEY=.*|MASTER_KEY=$$KEY|" .env; \
	else \
		echo "MASTER_KEY=$$KEY" >> .env; \
	fi; \
	echo "MASTER_KEY generated."

# Log in as admin (admin/Password01!) and mint a fresh API key, write it to
# .env. Idempotent — old keys aren't revoked. Useful both for first-time
# setup and after `make reset`.
mint-api-key:
	@COOKIE=$$(mktemp); \
	curl -sf -c "$$COOKIE" -X POST -H "Content-Type: application/json" \
	     -d '{"Username":"admin","Password":"Password01!"}' \
	     http://localhost:8090/api/users/login > /dev/null \
	  || { echo "Login failed — is Octopus up at http://localhost:8090?"; rm "$$COOKIE"; exit 1; }; \
	USER_ID=$$(curl -sf -b "$$COOKIE" http://localhost:8090/api/users/me | jq -r .Id); \
	CSRF=$$(grep -oE 'Octopus-Csrf-Token_[^[:space:]]+\s+[^[:space:]]+' "$$COOKIE" | awk '{print $$2}' | tail -1); \
	KEY=$$(curl -sf -b "$$COOKIE" -H "X-Octopus-Csrf-Token: $$CSRF" \
	     -H "Content-Type: application/json" -X POST \
	     -d '{"Purpose":"make mint-api-key"}' \
	     "http://localhost:8090/api/users/$$USER_ID/apikeys" | jq -r .ApiKey); \
	rm "$$COOKIE"; \
	if grep -q '^OCTOPUS_API_KEY=' .env; then \
		sed -i '' "s|^OCTOPUS_API_KEY=.*|OCTOPUS_API_KEY=$$KEY|" .env; \
	else \
		echo "OCTOPUS_API_KEY=$$KEY" >> .env; \
	fi; \
	echo "OCTOPUS_API_KEY written to .env (purpose=\"make mint-api-key\")"

# Full server-side reset. Wipes Helm releases, K8s namespace, tofu state,
# and compose volumes; reboots Octopus (licence auto-applies); mints a fresh
# API key; reapplies all three stacks; queues a target health check.
#
# Preserves: .env (incl. MASTER_KEY), GitHub repo, license.xml, .terraform/
# provider caches, defaults.auto.tfvars, OCL files in .octopus/.
reset:
	@echo "==> WARNING: full reset destroys local Octopus DB, K8s agent state, and tofu state."
	@read -p "    Continue? [y/N] " ans && [ "$$ans" = "y" ] || [ "$$ans" = "yes" ] || { echo "aborted"; exit 1; }
	@echo "==> uninstall this worktree's helm release + the shared CSI driver (ignore errors if absent)"
	@source .env && case "$$OCTOPUS_URL" in *octopus.app*) target=saas ;; *) target=local ;; esac; \
	  AGENT="$${OCTOPUS_AGENT_TARGET_NAME:-octopus-tentacle-$$target}"; NS="octopus-agent-$$AGENT"; \
	  helm uninstall $$AGENT -n $$NS 2>/dev/null || true; \
	  helm uninstall csi-driver-nfs -n kube-system 2>/dev/null || true; \
	  echo "==> force-clean stuck pods + namespace (ignore errors)"; \
	  kubectl -n $$NS delete pod --all --force --grace-period=0 2>/dev/null || true; \
	  kubectl delete ns $$NS --ignore-not-found 2>/dev/null || true; \
	  until ! kubectl get ns $$NS 2>/dev/null | grep -q Terminating; do printf '.'; sleep 2; done; echo
	@echo "==> remove tofu state"
	rm -f $(SPACE_DIR)/terraform.tfstate* $(CP_DIR)/terraform.tfstate* $(PH_DIR)/terraform.tfstate* $(APP_DIR)/terraform.tfstate* $(AGENT_DIR)/terraform.tfstate*
	@echo "==> wipe compose volumes (--remove-orphans catches containers from a different topology, e.g. switching HA → single-node)"
	$(COMPOSE) down -v --remove-orphans
	@echo "==> boot fresh Octopus (licence auto-applies via OCTOPUS_SERVER_BASE64_LICENSE)"
	$(MAKE) up
	@echo "==> wait for API"
	@until curl -sf http://localhost:8090/api > /dev/null 2>&1; do printf '.'; sleep 5; done; echo " up"
	@echo "==> mint a fresh API key (the old one in .env is invalid after the DB wipe)"
	$(MAKE) mint-api-key
	@echo "==> apply all stacks (TF_CLI_ARGS_apply=-auto-approve so the inner applies don't prompt)"
	TF_CLI_ARGS_apply=-auto-approve $(MAKE) apply
	@echo "==> reset complete — agent should report Healthy within ~30s"
