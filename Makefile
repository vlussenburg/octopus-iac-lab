# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml
SPACE_DIR := tofu/space
CP_DIR := tofu/control-plane
PH_DIR := tofu/platform-hub
APP_DIR := tofu/app-randomquotes
AGENT_DIR := tofu/k8s-agent
ARGO_DIR := tofu/argocd

# Load .env (secrets + per-target URL/key) and export TF_VAR_* for OpenTofu.
# Non-sensitive values come from each stack's committed defaults.auto.tfvars.
# OCTOPUS_URL is per-worktree: local has http://localhost:8090, SaaS has the
# https://<id>.octopus.app URL.
define load_env
	set -a; \
	[ -f .env ] || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }; \
	source .env; set +a; \
	[ -n "$$OCTOPUS_URL" ] || { echo "OCTOPUS_URL is unset in .env (e.g. http://localhost:8090 or https://<id>.octopus.app)"; exit 1; }; \
	export TF_VAR_octopus_url="$$OCTOPUS_URL" \
	       TF_VAR_octopus_api_key="$$OCTOPUS_API_KEY" \
	       TF_VAR_github_pat="$$GITHUB_PAT" \
	       TF_VAR_octopus_url_from_cluster="$${OCTOPUS_URL_FROM_CLUSTER:-http://host.docker.internal:8090}" \
	       TF_VAR_octopus_polling_url_from_cluster="$${OCTOPUS_POLLING_URL_FROM_CLUSTER:-https://host.docker.internal:10943}" \
	       TF_VAR_enable_platform_hub="$${OCTOPUS_PLATFORM_HUB_ENABLED:-true}";
endef

.PHONY: help \
        up down logs ps nuke \
        master-key mint-api-key ensure-api-key \
        space-init space-plan space-apply space-destroy space-fmt space-validate \
        cp-init cp-plan cp-apply cp-destroy cp-fmt cp-validate \
        ph-init ph-plan ph-apply ph-destroy ph-fmt ph-validate \
        app-init app-plan app-apply app-destroy app-fmt app-validate \
        agent-init agent-plan agent-apply agent-destroy agent-fmt agent-validate \
        argo-init argo-plan argo-apply argo-destroy argo-fmt argo-validate \
        fmt validate apply destroy rebuild

help:
	@echo "compose/              : up | down | logs | ps | nuke      (local self-host only)"
	@echo "bootstrap             : master-key (first-time) | mint-api-key (local-only)"
	@echo "deploys come from CI: push to main on github → .github/workflows/build.yml → release.yml"
	@echo "tofu/space/           : space-init | space-plan | space-apply | space-destroy | space-fmt | space-validate"
	@echo "tofu/control-plane/   : cp-init | cp-plan | cp-apply | cp-destroy | cp-fmt | cp-validate"
	@echo "tofu/platform-hub/    : ph-init | ph-plan | ph-apply | ph-destroy | ph-fmt | ph-validate"
	@echo "tofu/app-randomquotes/: app-init | app-plan | app-apply | app-destroy | app-fmt | app-validate"
	@echo "tofu/k8s-agent/       : agent-init | agent-plan | agent-apply | agent-destroy | agent-fmt | agent-validate"
	@echo "tofu/argocd/          : argo-init | argo-plan | argo-apply | argo-destroy | argo-fmt | argo-validate"
	@echo "convenience           : fmt (all) | validate (all) | apply (space,cp,ph,app,agent,argo) | destroy (rev) | rebuild (destroy + apply, non-interactive)"

# --- compose/ -------------------------------------------------------------

# Licence is read straight from .env as OCTOPUS_SERVER_BASE64_LICENSE — docker
# compose's --env-file picks it up and the Octopus image's install.sh applies
# it on boot. Encode once with `base64 -i license.xml | tr -d '\n'` and paste
# into .env. If the var is unset/empty the licence step is skipped (paste via
# UI under Configuration → License).
up:
	$(COMPOSE) up -d

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

# --- tofu/argocd/ ---------------------------------------------------------

argo-init:
	cd $(ARGO_DIR) && tofu init

argo-plan:
	$(load_env) cd $(ARGO_DIR) && tofu plan

argo-apply:
	$(load_env) cd $(ARGO_DIR) && tofu apply

argo-destroy:
	$(load_env) cd $(ARGO_DIR) && tofu destroy

argo-fmt:
	cd $(ARGO_DIR) && tofu fmt -recursive

argo-validate:
	cd $(ARGO_DIR) && tofu validate

# --- blue/green demo (Argo Rollouts) -------------------------------------
# Self-contained walkthrough — see demo/argocd-blue-green/README.md.
# Stays out of `apply` / `destroy` so production traffic never accidentally
# routes through a Rollout. Runs against the docker-desktop kube context.

BG_DEMO_NS  := argo-randomquotes-bg-demo
BG_DEMO_TPL := demo/argocd-blue-green/randomquotes-bg.yaml.tmpl
TAG         ?= pr-1

bg-demo-up:           ## Apply (or bump) the demo Application — TAG=pr-N
	@TAG=$(TAG) envsubst < $(BG_DEMO_TPL) | kubectl apply -f -
	@echo "Demo:  active=http://argo-bg.localtest.me:8080  preview=http://argo-bg-preview.localtest.me:8080"

bg-demo-promote:      ## Flip active Service from blue to green
	kubectl argo rollouts promote randomquotes -n $(BG_DEMO_NS)

bg-demo-abort:        ## Drop the green ReplicaSet, keep blue serving
	kubectl argo rollouts abort randomquotes -n $(BG_DEMO_NS)

bg-demo-status:       ## Show Rollout phase + ReplicaSets
	kubectl argo rollouts get rollout randomquotes -n $(BG_DEMO_NS)

bg-demo-down:         ## Tear down the demo (Application + namespace)
	-kubectl delete -n argocd application randomquotes-bg-demo --ignore-not-found
	-kubectl delete namespace $(BG_DEMO_NS) --ignore-not-found

# --- convenience ----------------------------------------------------------

fmt: space-fmt cp-fmt ph-fmt app-fmt agent-fmt argo-fmt
validate: space-validate cp-validate ph-validate app-validate agent-validate argo-validate

# Apply order: space → cp → ph → app → agent → argo. Every downstream stack
# reads space_id from tofu/space/ via terraform_remote_state, so space must
# apply first. App reads cp outputs too. argo reads space + cp + app
# (Application module references project slug from app stack). ensure-api-key
# runs first so a stale token (e.g. after a local DB wipe) is auto-recovered
# before any tofu work starts.
apply: ensure-api-key space-apply cp-apply ph-apply app-apply agent-apply argo-apply

# Destroy in reverse — argo first, space last. Destroying space cascades on
# the Octopus side (deleting the Space removes all child resources), but the
# *terraform state* of downstream stacks still references those resources, so
# we destroy them in dependency order to keep state coherent.
destroy: ensure-api-key argo-destroy agent-destroy app-destroy ph-destroy cp-destroy space-destroy

# Nuke-and-rebuild — non-interactive. Runs the full destroy chain then the
# full apply chain, both with -auto-approve, so two worktrees can be
# rebuilt in parallel without each prompting for confirmation:
#   make -C ../octopus-iac-lab-saas rebuild & make rebuild & wait
# Sandbox semantics — don't add this target to anything you can't afford to
# nuke without a second thought.
rebuild: ensure-api-key
	@$(load_env) \
	for d in $(ARGO_DIR) $(AGENT_DIR) $(APP_DIR) $(PH_DIR) $(CP_DIR) $(SPACE_DIR); do \
	  echo "=== destroy $$d ==="; \
	  ( cd $$d && tofu destroy -auto-approve ) || exit $$?; \
	done; \
	for d in $(SPACE_DIR) $(CP_DIR) $(PH_DIR) $(APP_DIR) $(AGENT_DIR) $(ARGO_DIR); do \
	  echo "=== apply $$d ==="; \
	  ( cd $$d && tofu apply -auto-approve ) || exit $$?; \
	done

# --- bootstrap helpers ----------------------------------------------------

# Generate a fresh 32-byte MASTER_KEY into .env. First-time setup only —
# refuses to overwrite an existing key (would orphan any data encrypted with
# the old one). To start fresh, see the manual wipe steps in README.md.
master-key:
	@CURRENT=$$(grep '^MASTER_KEY=' .env 2>/dev/null | cut -d= -f2-); \
	if [ -n "$$CURRENT" ] && [ "$$CURRENT" != "CHANGE_ME" ]; then \
		echo "MASTER_KEY already set in .env. Refusing to overwrite — see manual wipe steps in README.md."; \
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
# .env. Idempotent — old keys aren't revoked. Local self-host only; SaaS API
# keys must be minted in the UI (no admin/password to log in with).
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

# Probe the current OCTOPUS_API_KEY against /api/users/me. If unauthorised:
#   - local: silently mint a fresh key (admin/Password01! login still works
#     after a DB wipe)
#   - SaaS:  fail with a pointer to the UI, since we can't mint without a
#     session
# Apply / destroy depend on this so a stale token from `make nuke` (DB
# rebuilt, .env still pointing at the old key) auto-recovers.
ensure-api-key:
	@$(load_env) \
	  if curl -sf -o /dev/null -H "X-Octopus-ApiKey: $$OCTOPUS_API_KEY" "$$OCTOPUS_URL/api/users/me"; then \
	    :; \
	  else \
	    case "$$OCTOPUS_URL" in \
	      *octopus.app*) \
	        echo "OCTOPUS_API_KEY rejected by $$OCTOPUS_URL."; \
	        echo "Mint a new one at $$OCTOPUS_URL/app#/users/me/apiKeys and update .env."; \
	        exit 1 ;; \
	      *) \
	        echo "OCTOPUS_API_KEY rejected — local DB likely rebuilt. Minting fresh."; \
	        $(MAKE) mint-api-key ;; \
	    esac; \
	  fi
