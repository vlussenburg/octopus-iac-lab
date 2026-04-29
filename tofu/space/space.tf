# `is_task_queue_stopped = false` while we use the Space, but the destroy
# lifecycle of this resource flips it to true before issuing DELETE — that's
# the precondition Octopus enforces.
#
# `space_managers_teams = ["teams-administrators"]` makes the system Octopus
# Administrators team a manager. That team contains whoever owns the API key
# we're using, so the same person who creates the Space stays a manager of it
# without any per-instance user lookup.
resource "octopusdeploy_space" "this" {
  name                  = var.space_name
  description           = var.space_description
  is_default            = false
  is_task_queue_stopped = false
  space_managers_teams  = ["teams-administrators"]
}
