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

  # No hard limit could be derived from the agent: each SNMP target is its own collector
  # (a few goroutines and one UDP socket), the agent unit allows 65,535 open files, and
  # nothing in the agent caps the target count. 10,000 is the default the nearest
  # analogue already uses (`AddonProfile.max_targets`), and at roughly 300 bytes a target
  # in the shared-OID format it keeps one profile's config near 3 MB.
  @default_snmp_max_targets 10_000

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

  @doc "The SNMP target limit used when no scope sets one: 10,000 targets per profile per agent."
  @spec default_snmp_max_targets() :: pos_integer()
  def default_snmp_max_targets, do: @default_snmp_max_targets

  @doc """
  The most targets one SNMP profile may compile for an agent: the agent's value, else its
  partition's, else the global row's, else the default. `agent_id` may be `nil` for a
  profile that is not being compiled for a particular agent; only the partition and
  global rows apply then.
  """
  @spec snmp_max_targets(String.t() | nil, String.t() | nil) ::
          {:ok, pos_integer()} | {:error, term()}
  def snmp_max_targets(agent_id, partition_id)
      when (is_binary(agent_id) or is_nil(agent_id)) and
             (is_binary(partition_id) or is_nil(partition_id)) do
    with {:ok, rows} <- read_rows(agent_id || "", partition_id) do
      by_scope = Map.new(rows, &{&1.scope, &1})
      ordered = Enum.flat_map([:agent, :partition, :global], &List.wrap(by_scope[&1]))

      {:ok, first_value(ordered, :snmp_max_targets) || @default_snmp_max_targets}
    end
  end

  @doc """
  The settings that apply to an agent in a partition (`partition_id` is the partition's id).
  With a `nil` partition, an agent whose partition has no row, only the agent and global rows
  apply.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, resolved()} | {:error, term()}
  def resolve(agent_id, partition_id)
      when is_binary(agent_id) and (is_binary(partition_id) or is_nil(partition_id)) do
    with {:ok, rows} <- read_rows(agent_id, partition_id) do
      {:ok, combine(rows)}
    end
  end

  defp read_rows(agent_id, partition_id) do
    query =
      Ash.Query.filter(
        PipelineSetting,
        scope == :global or (scope == :agent and scope_key == ^agent_id) or
          (scope == :partition and scope_key == ^(partition_id || ""))
      )

    Ash.read(query, actor: SystemActor.system(:edge_pipeline_settings))
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
