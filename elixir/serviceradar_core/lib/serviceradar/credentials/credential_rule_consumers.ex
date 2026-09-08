defmodule ServiceRadar.Credentials.CredentialRuleConsumers do
  @moduledoc """
  Derives per-rule materialization consumers from existing policy-derived
  plugin assignments.

  The materializer stamps every assignment it writes with
  `policy_id: "network-credential-rule:<rule id>[:<purpose>]"`, so a rule's
  current consumers (agents, plugins, purposes, last materialization time) can
  be answered from the `plugin_assignments` table alone — no new state.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query

  @policy_prefix "network-credential-rule:"

  @typedoc "One materialized assignment attributed to a rule."
  @type consumer :: %{
          agent_uid: String.t() | nil,
          plugin_id: String.t() | nil,
          purpose: String.t() | nil,
          enabled: boolean(),
          last_materialized_at: DateTime.t() | nil
        }

  @typedoc "Aggregated consumer view for one rule."
  @type summary :: %{
          total: non_neg_integer(),
          enabled_count: non_neg_integer(),
          agent_uids: [String.t()],
          plugin_ids: [String.t()],
          last_materialized_at: DateTime.t() | nil,
          consumers: [consumer()]
        }

  @doc """
  Lists the agents/plugins a credential rule currently materializes for.

  Queries policy assignments by the `network-credential-rule:<rule id>` prefix
  (rule ids are fixed-length UUIDs, so a prefix match cannot collide with a
  different rule).
  """
  @spec list_for_rule(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def list_for_rule(rule_id, opts \\ []) when is_binary(rule_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_rule_consumers))
    prefix = @policy_prefix <> rule_id
    pattern = prefix <> "%"

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == :policy and like(policy_id, ^pattern))
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} -> {:ok, summarize(prefix, assignments)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec summarize(String.t(), [map()]) :: summary()
  def summarize(prefix, assignments) when is_binary(prefix) and is_list(assignments) do
    consumers =
      assignments
      |> Enum.map(fn assignment ->
        %{
          agent_uid: field(assignment, :agent_uid),
          plugin_id: field(assignment, :plugin_id),
          purpose: purpose_from_policy_id(prefix, field(assignment, :policy_id)),
          enabled: field(assignment, :enabled) != false,
          last_materialized_at: field(assignment, :updated_at)
        }
      end)
      |> Enum.sort_by(&{&1.agent_uid || "", &1.plugin_id || "", &1.purpose || ""})

    %{
      total: length(consumers),
      enabled_count: Enum.count(consumers, & &1.enabled),
      agent_uids: consumers |> Enum.map(& &1.agent_uid) |> uniq_strings(),
      plugin_ids: consumers |> Enum.map(& &1.plugin_id) |> uniq_strings(),
      last_materialized_at: latest_timestamp(consumers),
      consumers: consumers
    }
  end

  defp purpose_from_policy_id(prefix, policy_id) when is_binary(policy_id) do
    case String.replace_prefix(policy_id, prefix, "") do
      "" -> "inventory_enrichment"
      ":" <> purpose -> purpose
      _other -> nil
    end
  end

  defp purpose_from_policy_id(_prefix, _policy_id), do: nil

  defp uniq_strings(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp latest_timestamp(consumers) do
    consumers
    |> Enum.map(& &1.last_materialized_at)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
