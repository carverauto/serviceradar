defmodule ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery do
  @moduledoc """
  Validates that the target_query attribute is a valid SRQL query.

  If target_query is nil or empty, validation passes (no targeting = default behavior).
  If target_query is provided, it must parse successfully via the SRQL NIF.

  Unlike sysmon profiles which only target devices, SNMP profiles can target
  both devices and interfaces:
  - `in:devices tags.role:network-monitor` - Target devices
  - `in:interfaces type:ethernet` - Target interfaces
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.ValidateTargetQuery

  @impl true
  def change(changeset, _opts, _context) do
    ValidateTargetQuery.change(changeset,
      allowed_targets: [:devices, :interfaces],
      default_target: :devices
    )
  end
end
