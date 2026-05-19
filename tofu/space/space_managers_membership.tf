# Add the API-key user to the auto-created `Space Managers` team for this
# Space.
#
# `space_managers_teams` on the Space resource grants the listed teams the
# manager role, but Octopus's manual-intervention permission check matches by
# *direct* team membership — being in `Octopus Administrators` (which IS a
# space-manager team here) isn't enough to act on an interruption whose
# ResponsibleTeamId is `teams-spacemanagers-Spaces-N`. The auto-created
# per-space team has zero members by default, leaving manual-intervention
# steps un-actionable.
#
# Adopt the auto-created team via `import` and manage its `users` attribute.

variable "space_manager_username" {
  type        = string
  description = "Username (or partial) of the user added to Space Managers. Defaults to the local bootstrap admin; override per-target via TF_VAR_space_manager_username for SaaS."
  default     = "admin"
}

data "octopusdeploy_users" "space_manager" {
  filter = var.space_manager_username
}

resource "octopusdeploy_team" "space_managers" {
  name     = "Space Managers"
  space_id = octopusdeploy_space.this.id
  users    = [data.octopusdeploy_users.space_manager.users[0].id]

  # The auto-created Space Managers team comes pre-bound to the
  # `userroles-spacemanager` scoped role. Without this block, the provider
  # reads the role on import, sees no matching block in config, and tries
  # to delete it on apply — Octopus rejects with "The Space Manager Team
  # must have a Space Manager User Role". Declaring it explicitly here
  # makes the diff a no-op.
  user_role {
    space_id     = octopusdeploy_space.this.id
    user_role_id = "userroles-spacemanager"
  }

  lifecycle {
    # Name + space_id are fixed by Octopus on the auto-created team.
    ignore_changes = [name]
  }
}

import {
  to = octopusdeploy_team.space_managers
  id = "teams-spacemanagers-${octopusdeploy_space.this.id}"
}
