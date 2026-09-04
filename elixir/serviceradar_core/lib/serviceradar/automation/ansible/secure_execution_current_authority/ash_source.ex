defmodule ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.AshSource do
  @moduledoc """
  Fresh persistence reads for non-callback AWX launch authorization.

  The delegated source uses a `SystemActor` only to cross persistence policy
  boundaries. It returns the initiating principal, that principal's strict
  effective authority snapshot, current memberships, reviewed binding, and holds; system authority
  is never returned or treated as launch authority.
  """

  @behaviour ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.Source

  alias ServiceRadar.Automation.CallbackGrants.CurrentAuthorityAshSource

  @impl true
  defdelegate load_principal(principal_type, principal_id, owner_id),
    to: CurrentAuthorityAshSource

  @impl true
  defdelegate load_memberships(membership_ids), to: CurrentAuthorityAshSource

  @impl true
  defdelegate load_current_binding(controller_id, job_template_id),
    to: CurrentAuthorityAshSource

  @impl true
  defdelegate active_holds(device_uids), to: CurrentAuthorityAshSource
end
