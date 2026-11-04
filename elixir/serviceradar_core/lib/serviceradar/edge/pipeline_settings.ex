defmodule ServiceRadar.Edge.PipelineSettings do
  @moduledoc """
  Resolves the edge pipeline settings that apply to an agent: how far ahead core leases its
  sweeps, and its spool byte budget.

  Each field takes the agent's value, else its partition's, else the global row's, else the
  code default below; the horizon is then capped at the administrator maximum. A deployment
  with no rows runs on the defaults. Nothing here turns the pipeline on or off.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.PipelineSetting

  require Ash.Query

  @default_horizon_seconds 7 * 86_400
  @default_max_horizon_seconds 30 * 86_400
  @default_spool_max_bytes 1024 * 1024 * 1024

  @type resolved :: %{horizon_seconds: pos_integer(), spool_max_bytes: pos_integer()}

  @doc "The horizon used when no scope sets one: seven days."
  @spec default_horizon_seconds() :: pos_integer()
  def default_horizon_seconds, do: @default_horizon_seconds

  @doc "The ceiling used when the global row sets none: thirty days."
  @spec default_max_horizon_seconds() :: pos_integer()
  def default_max_horizon_seconds, do: @default_max_horizon_seconds

  @doc "The spool budget used when no scope sets one: 1 GiB."
  @spec default_spool_max_bytes() :: pos_integer()
  def default_spool_max_bytes, do: @default_spool_max_bytes

  @doc """
  The settings that apply to an agent in a partition (`partition_id` is the partition's id).
  With a `nil` partition, an agent whose partition has no row, only the agent and global rows
  apply.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, resolved()} | {:error, term()}
  def resolve(agent_id, partition_id)
      when is_binary(agent_id) and (is_binary(partition_id) or is_nil(partition_id)) do
    query =
      Ash.Query.filter(
        PipelineSetting,
        scope == :global or (scope == :agent and scope_key == ^agent_id) or
          (scope == :partition and scope_key == ^(partition_id || ""))
      )

    with {:ok, rows} <- Ash.read(query, actor: SystemActor.system(:edge_pipeline_settings)) do
      {:ok, combine(rows)}
    end
  end

  @doc false
  @spec combine([PipelineSetting.t()]) :: resolved()
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
      horizon_seconds: min(horizon, max),
      spool_max_bytes: first_value(ordered, :spool_max_bytes) || @default_spool_max_bytes
    }
  end

  defp first_value(rows, field), do: Enum.find_value(rows, &Map.fetch!(&1, field))
end
