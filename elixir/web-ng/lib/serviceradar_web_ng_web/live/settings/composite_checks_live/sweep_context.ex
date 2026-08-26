defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.SweepContext do
  @moduledoc """
  The sweep groups that actually feed each vantage point.

  Composite checks derive rather than probe: a vantage point reads whatever the
  sweeps already produced for its agent. Which sweeps those are is not a single
  "scan profile" — `SweepGroup.agent_id` is nullable and means "any agent in
  partition", so an agent is covered by every group explicitly assigned to it
  *plus* every unassigned group in its partition. Showing one group as "the
  profile" would misstate which ports are probed.

  Read-only. Editing belongs to sweep administration, which owns these records.
  """

  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query

  @default_partition "default"

  @type group_view :: %{
          id: Ash.UUID.t(),
          name: String.t(),
          assigned?: boolean(),
          ports: [integer()],
          modes: [String.t()],
          interval: String.t() | nil,
          profile_name: String.t() | nil
        }

  @type entry :: %{
          key: String.t(),
          label: String.t(),
          agent_id: String.t() | nil,
          partition: String.t(),
          groups: [group_view()]
        }

  @doc """
  Sweep coverage for a check's vantage point inputs, in authoring order.

  Returns one entry per vantage point, each with every covering group. An entry
  with an empty `groups` list is the case that matters most: that vantage point
  will resolve `unknown` forever, and the panel has to say so rather than render
  nothing.
  """
  @spec for_inputs([struct()], [struct()], keyword()) :: [entry()]
  def for_inputs(inputs, agents, opts \\ []) do
    agents_by_uid = Map.new(agents, &{&1.uid, &1})

    inputs
    |> Enum.filter(&(&1.kind == :vantage_point))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn input ->
      agent_id = Map.get(input.config, "agent_id")
      partition = partition_for(Map.get(agents_by_uid, agent_id))

      %{
        key: input.key,
        label: input.label || input.key,
        agent_id: agent_id,
        partition: partition,
        groups: groups_for(agent_id, partition, opts)
      }
    end)
  end

  # An agent's partition lives in its metadata, which is the convention the
  # mapper job UI already uses (`mapper_options.ex`). An agent that reports no
  # partition is in "default", which is also `SweepGroup.partition`'s default,
  # so the two agree without a special case.
  defp partition_for(nil), do: @default_partition

  defp partition_for(agent) do
    case agent.metadata do
      %{"partition_id" => partition} when is_binary(partition) and partition != "" -> partition
      _other -> @default_partition
    end
  end

  defp groups_for(nil, _partition, _opts), do: []

  # `:for_agent_partition` is the read whose filter is: enabled, and either
  # assigned to this agent (including isolation scans whose device partition
  # differs) or unassigned in this agent's partition. `:by_agent` ignores
  # partition entirely and would credit a vantage with every unassigned group.
  defp groups_for(agent_id, partition, opts) do
    SweepGroup
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent_id, partition: partition})
    |> Ash.Query.load(:profile)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(opts)
    |> case do
      {:ok, groups} -> Enum.map(groups, &group_view(&1, agent_id))
      {:error, _reason} -> []
    end
  end

  # Ports and modes on a group are *overrides* of its profile, so the effective
  # value is the override when present and the profile's otherwise. Rendering
  # the group's own nil would claim no ports are probed when the profile names
  # a dozen.
  defp group_view(group, agent_id) do
    %{
      id: group.id,
      name: group.name,
      assigned?: group.agent_id == agent_id,
      ports: group.ports || profile_field(group, :ports) || [],
      modes: group.sweep_modes || profile_field(group, :sweep_modes) || [],
      interval: group.interval,
      profile_name: profile_field(group, :name)
    }
  end

  defp profile_field(%{profile: %Ash.NotLoaded{}}, _field), do: nil
  defp profile_field(%{profile: nil}, _field), do: nil
  defp profile_field(%{profile: profile}, field), do: Map.get(profile, field)
  defp profile_field(_group, _field), do: nil
end
