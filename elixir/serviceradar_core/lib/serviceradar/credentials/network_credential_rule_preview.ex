defmodule ServiceRadar.Credentials.NetworkCredentialRulePreview do
  @moduledoc """
  Previews network credential rule target matches and equal-priority conflicts.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PluginInputPayloadBuilder
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @type preview_result :: %{
          rule_id: String.t() | nil,
          matched_devices: non_neg_integer(),
          scoped_devices: non_neg_integer(),
          agents: [map()],
          sample_devices: [map()],
          conflicts: [map()]
        }

  @spec preview_by_id(String.t(), keyword()) :: {:ok, preview_result()} | {:error, term()}
  def preview_by_id(id, opts \\ []) when is_binary(id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:network_credential_rule_preview))

    with {:ok, %NetworkCredentialRule{} = rule} <-
           NetworkCredentialRule.get_by_id(id, actor: actor),
         {:ok, other_rules} <- load_conflict_candidates(rule, actor, opts) do
      preview_rule(rule, Keyword.put(opts, :other_rules, other_rules))
    end
  end

  @spec preview_rule(map(), keyword()) :: {:ok, preview_result()} | {:error, term()}
  def preview_rule(rule, opts \\ [])

  def preview_rule(rule, opts) when is_map(rule) do
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)
    sample_limit = Keyword.get(opts, :sample_limit, 10)

    with {:ok, input_def} <- input_definition(rule),
         {:ok, resolved_inputs} <- resolver.resolve([input_def], opts) do
      rows = resolved_device_rows(resolved_inputs)
      scoped_rows = Enum.filter(rows, &in_rule_scope?(&1, rule))

      {:ok,
       %{
         rule_id: value_string(rule, [:id, "id"]),
         matched_devices: length(rows),
         scoped_devices: length(scoped_rows),
         agents: agent_distribution(scoped_rows),
         sample_devices: Enum.take(scoped_rows, sample_limit),
         conflicts: detect_conflicts(rule, scoped_rows, opts)
       }}
    end
  end

  def preview_rule(_rule, _opts), do: {:error, :invalid_rule}

  defp load_conflict_candidates(rule, actor, opts) do
    if Keyword.get(opts, :detect_conflicts?, true) do
      with {:ok, provider} <- required_string(rule, [:provider, "provider"], "provider"),
           {:ok, scope_type} <- required_scope_type(rule),
           {:ok, scope_value} <-
             required_string(rule, [:scope_value, "scope_value"], "scope_value") do
        NetworkCredentialRule.list_enabled_for_scope(provider, scope_type, scope_value,
          actor: actor
        )
      end
    else
      {:ok, []}
    end
  end

  defp input_definition(rule) do
    with {:ok, query} <- required_string(rule, [:target_query, "target_query"], "target_query") do
      {:ok, %{name: "targets", entity: "devices", query: query}}
    end
  end

  defp resolved_device_rows(resolved_inputs) do
    resolved_inputs
    |> Enum.flat_map(fn input ->
      entity = ValueUtils.string_value(input, [:entity, "entity"]) || "devices"
      rows = ValueUtils.list_value(input, [:rows, "rows"]) || []

      rows
      |> Enum.map(&normalize_device_row(entity, &1))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(&device_uid/1)
  end

  defp normalize_device_row(entity, row) when is_map(row) do
    string_row = MapUtils.stringify_keys(row)

    case PluginInputPayloadBuilder.normalize_rows(entity, [string_row]) do
      [normalized] -> Map.merge(string_row, normalized)
      [] -> nil
    end
  end

  defp normalize_device_row(_entity, _row), do: nil

  defp in_rule_scope?(row, rule) do
    case {rule_scope_type(rule), value_string(rule, [:scope_value, "scope_value"])} do
      {:agent, scope} ->
        case value_string(row, [:agent_id, "agent_id", :agent_uid, "agent_uid"]) do
          nil -> true
          "" -> true
          row_scope -> row_scope == scope
        end

      {:gateway, scope} ->
        value_string(row, [:gateway_id, "gateway_id"]) == scope

      {:partition, scope} ->
        value_string(row, [:partition_id, "partition_id", :partition, "partition", :site, "site"]) ==
          scope

      _ ->
        false
    end
  end

  defp agent_distribution(rows) do
    rows
    |> Enum.group_by(&agent_id/1)
    |> Enum.reject(fn {agent_id, _rows} -> ValueUtils.blank_string?(agent_id) end)
    |> Enum.map(fn {agent_id, agent_rows} ->
      %{
        agent_id: agent_id,
        device_count: length(agent_rows),
        sample_devices: Enum.take(agent_rows, 5)
      }
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  defp detect_conflicts(rule, scoped_rows, opts) do
    other_rules = Keyword.get(opts, :other_rules, [])
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)
    current_devices = MapSet.new(Enum.map(scoped_rows, &device_uid/1))

    other_rules
    |> Enum.reject(&(value_string(&1, [:id, "id"]) == value_string(rule, [:id, "id"])))
    |> Enum.filter(&same_conflict_group?(rule, &1))
    |> Enum.flat_map(fn other_rule ->
      conflict_for_rule(rule, other_rule, current_devices, resolver, opts)
    end)
  end

  defp conflict_for_rule(rule, other_rule, current_devices, resolver, opts) do
    with true <- rule_priority(rule) == rule_priority(other_rule),
         {:ok, input_def} <- input_definition(other_rule),
         {:ok, resolved_inputs} <- resolver.resolve([input_def], opts) do
      overlap =
        resolved_inputs
        |> resolved_device_rows()
        |> Enum.filter(&in_rule_scope?(&1, other_rule))
        |> Enum.map(&device_uid/1)
        |> Enum.filter(&MapSet.member?(current_devices, &1))

      case overlap do
        [] ->
          []

        _ ->
          [
            %{
              rule_id: value_string(other_rule, [:id, "id"]),
              priority: rule_priority(other_rule),
              overlapping_devices: length(overlap),
              sample_device_uids: Enum.take(overlap, 10)
            }
          ]
      end
    else
      _ -> []
    end
  end

  defp same_conflict_group?(left, right) do
    value_string(left, [:provider, "provider"]) == value_string(right, [:provider, "provider"]) and
      rule_purpose(left) == rule_purpose(right) and
      rule_scope_type(left) == rule_scope_type(right) and
      value_string(left, [:scope_value, "scope_value"]) ==
        value_string(right, [:scope_value, "scope_value"])
  end

  defp device_uid(row), do: value_string(row, [:uid, "uid", :device_uid, "device_uid", :id, "id"])

  defp agent_id(row), do: value_string(row, [:agent_id, "agent_id", :agent_uid, "agent_uid"])

  defp rule_priority(rule), do: ValueUtils.int_value(rule, [:priority, "priority"], 100)

  defp rule_purpose(rule), do: value_string(rule, [:purpose, "purpose"]) || "inventory_enrichment"

  defp rule_scope_type(rule) do
    case value_string(rule, [:scope_type, "scope_type"]) do
      "agent" -> :agent
      "gateway" -> :gateway
      "partition" -> :partition
      _ -> nil
    end
  end

  defp required_scope_type(rule) do
    case rule_scope_type(rule) do
      value when value in [:agent, :gateway, :partition] -> {:ok, value}
      _ -> {:error, {:missing_required_field, "scope_type"}}
    end
  end

  defp required_string(map, keys, label) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, label}}
    end
  end

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)
end
