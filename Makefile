# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml
CP_DIR := tofu/control-plane
APP_DIR := tofu/app-randomquotes
AGENT_DIR := tofu/k8s-agent

# Load .env (secrets only) and export TF_VAR_* for OpenTofu. Non-sensitive
# values come from each stack's committed defaults.auto.tfvars.
define load_env
	set -a; \
	[ -f .env ] || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }; \
	source .env; set +a; \
	export TF_VAR_octopus_api_key="$$OCTOPUS_API_KEY" \
	       TF_VAR_github_pat="$$GITHUB_PAT";
endef

.PHONY: help \
        up down logs ps nuke \
        cp-init cp-plan cp-apply cp-destroy cp-fmt cp-validate \
        app-init app-plan app-apply app-destroy app-fmt app-validate \
        agent-init agent-plan agent-apply agent-destroy agent-fmt agent-validate \
        fmt validate apply destroy

help:
	@echo "compose/              : up | down | logs | ps | nuke"
	@echo "tofu/control-plane/   : cp-init | cp-plan | cp-apply | cp-destroy | cp-fmt | cp-validate"
	@echo "tofu/app-randomquotes/: app-init | app-plan | app-apply | app-destroy | app-fmt | app-validate"
	@echo "tofu/k8s-agent/       : agent-init | agent-plan | agent-apply | agent-destroy | agent-fmt | agent-validate"
	@echo "convenience           : fmt (all) | validate (all) | apply (cp,app) | destroy (app,cp)"

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

fmt: cp-fmt app-fmt agent-fmt
validate: cp-validate app-validate agent-validate

# Apply must run cp first then app — app reads cp state. Agent is independent
# but reads cp state too, so it goes after cp.
apply: cp-apply app-apply agent-apply

# Destroy in reverse.
destroy: agent-destroy app-destroy cp-destroy
