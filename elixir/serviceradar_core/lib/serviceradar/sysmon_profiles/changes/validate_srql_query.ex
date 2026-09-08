defmodule ServiceRadar.SysmonProfiles.Changes.ValidateSrqlQuery do
  @moduledoc """
  Validates that the target_query attribute is a valid SRQL query.

  If target_query is nil or empty, validation passes (no targeting = profile will not match).
  If target_query is provided, it must parse successfully via the SRQL NIF.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.ValidateTargetQuery

  @impl true
  def change(changeset, _opts, _context) do
    ValidateTargetQuery.change(changeset, allowed_targets: [:devices], default_target: :devices)
  end
end
