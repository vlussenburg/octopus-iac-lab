# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
TF_DIR := tofu
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml

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

.PHONY: help up down logs ps nuke init plan apply destroy fmt validate console

help:
	@echo "compose/   : up | down | logs | ps | nuke"
	@echo "tofu/      : init | plan | apply | destroy | fmt | validate | console"

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

# --- tofu/ ----------------------------------------------------------------

init:
	cd $(TF_DIR) && tofu init

plan:
	$(load_env) cd $(TF_DIR) && tofu plan

apply:
	$(load_env) cd $(TF_DIR) && tofu apply

destroy:
	$(load_env) cd $(TF_DIR) && tofu destroy

fmt:
	cd $(TF_DIR) && tofu fmt -recursive

validate:
	cd $(TF_DIR) && tofu validate

console:
	$(load_env) cd $(TF_DIR) && tofu console
