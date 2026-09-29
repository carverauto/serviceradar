defmodule ServiceRadar.SweepJobs.LeaseSettings do
  @moduledoc """
  Resolves whether core schedules an agent's sweeps ahead of time, and how far ahead.

  Each field takes the agent's value, else its partition's, else the global row's, else the
  default below; the horizon is then capped at the administrator maximum. Leasing is off
  unless an operator turned it on, so a deployment with no rows leases nothing.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

  require Ash.Query

  @default_horizon_seconds 7 * 86_400
  @default_max_horizon_seconds 30 * 86_400

  @type resolved :: %{enabled?: boolean(), horizon_seconds: pos_integer()}

  @doc "The horizon used when no scope sets one: seven days."
  @spec default_horizon_seconds() :: pos_integer()
  def default_horizon_seconds, do: @default_horizon_seconds

  @doc "The ceiling used when the global row sets none: thirty days."
  @spec default_max_horizon_seconds() :: pos_integer()
  def default_max_horizon_seconds, do: @default_max_horizon_seconds

  @doc """
  The settings that apply to an agent in a partition (`partition_id` is the partition's id).
  """
  @spec resolve(String.t(), String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(agent_id, partition_id) when is_binary(agent_id) and is_binary(partition_id) do
    query =
      Ash.Query.filter(
        SweepLeaseSetting,
        scope == :global or (scope == :partition and scope_key == ^partition_id) or
          (scope == :agent and scope_key == ^agent_id)
      )

    with {:ok, rows} <- Ash.read(query, actor: SystemActor.system(:sweep_lease_settings)) do
      {:ok, combine(rows)}
    end
  end

  @doc false
  @spec combine([SweepLeaseSetting.t()]) :: resolved()
  def combine(rows) do
    by_scope = Map.new(rows, &{&1.scope, &1})
    ordered = Enum.flat_map([:agent, :partition, :global], &List.wrap(by_scope[&1]))

    max =
      case by_scope[:global] do
        %{max_horizon_seconds: value} when is_integer(value) -> value
        _ -> @default_max_horizon_seconds
      end

    horizon = first_value(ordered, :horizon_seconds) || @default_horizon_seconds

    %{
      enabled?: first_value(ordered, :leasing_enabled) == true,
      horizon_seconds: min(horizon, max)
    }
  end

  # The first scope that sets the field. A set value of `false` counts as set, so it is
  # wrapped: `Enum.find_value/2` would otherwise skip it.
  defp first_value(rows, field) do
    case Enum.find_value(rows, &set_value(&1, field)) do
      {value} -> value
      nil -> nil
    end
  end

  defp set_value(row, field) do
    case Map.fetch!(row, field) do
      nil -> nil
      value -> {value}
    end
  end
end
