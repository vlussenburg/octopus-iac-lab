# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key come
# in via TF_VAR_* exports from .env. octopus_space comes from tofu/space/
# via terraform_remote_state.
cac_repo_url  = "https://github.com/vlussenburg/octopus-iac-lab.git"
cac_branch    = "main"
cac_base_path = ".octopus"
