defmodule ServiceRadar.Automation.CallbackGrants.ActionContract do
  @moduledoc """
  Lifecycle access to the source-controlled callback action registry.

  The lifecycle does not maintain a second action catalog. It selects the exact
  reviewed version and enforces its deployment maximum before minting a grant.
  """

  alias ServiceRadar.Automation.Callbacks.ActionRegistry

  @version "1.0.0"

  @spec fetch(binary()) :: {:ok, map()} | {:error, term()}
  def fetch(action), do: ActionRegistry.fetch(action, @version)

  @spec required_permissions(map()) :: [binary()]
  def required_permissions(contract), do: Enum.sort(contract.required_permissions)

  @spec validate_deployment(map(), map()) :: :ok | {:error, term()}
  def validate_deployment(contract, response_snapshot) when is_map(response_snapshot) do
    maximum = contract.deployment_maximum
    operation = value(response_snapshot, :operation)
    phase = value(response_snapshot, :phase)
    state = value(response_snapshot, :state)
    targets = List.wrap(value(response_snapshot, :targets))

    cond do
      operation not in maximum["operations"] ->
        {:error, :operation_outside_deployment_maximum}

      phase not in maximum["phases"] ->
        {:error, :phase_outside_deployment_maximum}

      state not in maximum["states"] ->
        {:error, :state_outside_deployment_maximum}

      length(targets) > maximum["max_targets"] ->
        {:error, :target_count_outside_deployment_maximum}

      true ->
        :ok
    end
  end

  def validate_deployment(_contract, _response_snapshot),
    do: {:error, :callback_response_snapshot_required}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
