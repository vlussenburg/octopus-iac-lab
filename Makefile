# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml
CP_DIR := tofu/control-plane
APP_DIR := tofu/app-randomquotes

# Load .env and export every var it defines as TF_VAR_<lowercase>.
define load_env
	set -a; \
	[ -f .env ] || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }; \
	source .env; set +a; \
	export TF_VAR_octopus_url="$$OCTOPUS_URL" \
	       TF_VAR_octopus_space="$$OCTOPUS_SPACE" \
	       TF_VAR_octopus_api_key="$$OCTOPUS_API_KEY" \
	       TF_VAR_github_pat="$$GITHUB_PAT" \
	       TF_VAR_cac_repo_url="$$CAC_REPO_URL" \
	       TF_VAR_cac_branch="$$CAC_BRANCH" \
	       TF_VAR_cac_base_path="$$CAC_BASE_PATH";
endef

.PHONY: help \
        up down logs ps nuke \
        cp-init cp-plan cp-apply cp-destroy cp-fmt cp-validate \
        app-init app-plan app-apply app-destroy app-fmt app-validate \
        fmt validate apply destroy

help:
	@echo "compose/             : up | down | logs | ps | nuke"
	@echo "tofu/control-plane/  : cp-init | cp-plan | cp-apply | cp-destroy | cp-fmt | cp-validate"
	@echo "tofu/app-randomquotes/: app-init | app-plan | app-apply | app-destroy | app-fmt | app-validate"
	@echo "convenience          : fmt (both) | validate (both) | apply (cp then app) | destroy (app then cp)"

# --- compose/ -------------------------------------------------------------

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f octopus

ps:
	$(COMPOSE) ps

nuke:
	@read -p "This deletes the local Octopus DB. Continue? [y/N] " ans && [ "$$ans" = "y" ]
	$(COMPOSE) down -v

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

# --- convenience ----------------------------------------------------------

fmt: cp-fmt app-fmt
validate: cp-validate app-validate

# Apply must run cp first then app — app reads cp state.
apply: cp-apply app-apply

# Destroy in reverse — app first, then cp.
destroy: app-destroy cp-destroy
