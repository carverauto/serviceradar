defmodule ServiceRadar.Plugins.PolicyAssignmentPlanner do
  @moduledoc """
  Plans desired plugin assignments from policy-resolved input rows.

  This module does not persist assignments. It deterministically produces
  assignment specs keyed by policy/agent/chunk so a reconciler can upsert and
  disable stale rows.
  """

  alias ServiceRadar.Plugins.{MapUtils, PluginInputPayloadBuilder, ValueUtils}

  @type policy_config :: %{
          required(:policy_id) => String.t(),
          required(:policy_version) => pos_integer(),
          required(:plugin_package_id) => String.t(),
          optional(:params_template) => map(),
          optional(:enabled) => boolean(),
          optional(:interval_seconds) => pos_integer(),
          optional(:timeout_seconds) => pos_integer()
        }

  @spec plan(policy_config(), [map()], keyword()) ::
          {:ok, %{assignments: [map()], summary: map()}} | {:error, [String.t()]}
  def plan(policy, resolved_inputs, opts \\ [])

  def plan(policy, resolved_inputs, opts) when is_map(policy) and is_list(resolved_inputs) do
    with {:ok, normalized_policy} <- normalize_policy(policy),
         grouped <- group_rows_by_agent(resolved_inputs),
         {:ok, assignments} <- build_assignments(normalized_policy, grouped, opts) do
      summary = %{
        matched_rows: grouped.total_rows,
        agents: map_size(grouped.by_agent),
        generated_assignments: length(assignments)
      }

      {:ok, %{assignments: assignments, summary: summary}}
    end
  end

  def plan(_policy, _resolved_inputs, _opts),
    do: {:error, ["policy must be an object and resolved inputs must be a list"]}

  defp build_assignments(policy, grouped, opts) do
    generated_at = Keyword.get(opts, :generated_at, DateTime.utc_now() |> DateTime.to_iso8601())
    chunk_size = Keyword.get(opts, :chunk_size, 100)
    hard_limit_bytes = Keyword.get(opts, :hard_limit_bytes)

    grouped.by_agent
    |> Enum.sort_by(fn {agent_id, _} -> agent_id end)
    |> Enum.reduce_while({:ok, []}, fn {agent_id, inputs_for_agent}, {:ok, acc} ->
      base_payload = %{
        "policy_id" => policy.policy_id,
        "policy_version" => policy.policy_version,
        "agent_id" => agent_id,
        "generated_at" => generated_at,
        "template" => policy.params_template
      }

      builder_opts =
        [chunk_size: chunk_size]
        |> maybe_put(:hard_limit_bytes, hard_limit_bytes)

      case PluginInputPayloadBuilder.build_payloads(base_payload, inputs_for_agent, builder_opts) do
        {:ok, payloads} ->
          assignment_specs =
            Enum.map(payloads, &assignment_spec(policy, agent_id, &1))

          {:cont, {:ok, acc ++ assignment_specs}}

        {:error, errors} ->
          {:halt, {:error, errors}}
      end
    end)
  end

  defp normalize_policy(policy) do
    with {:ok, policy_id} <- required_string(policy, [:policy_id, "policy_id"], "policy_id"),
         {:ok, policy_version} <-
           required_positive_int(policy, [:policy_version, "policy_version"], "policy_version"),
         {:ok, plugin_package_id} <-
           required_string(policy, [:plugin_package_id, "plugin_package_id"], "plugin_package_id") do
      {:ok,
       %{
         policy_id: policy_id,
         policy_version: policy_version,
         plugin_package_id: plugin_package_id,
         params_template:
           ValueUtils.map_value(policy, [:params_template, "params_template"]) || %{},
         enabled: ValueUtils.bool_value(policy, [:enabled, "enabled"], true),
         interval_seconds:
           ValueUtils.int_value(policy, [:interval_seconds, "interval_seconds"], 60),
         timeout_seconds: ValueUtils.int_value(policy, [:timeout_seconds, "timeout_seconds"], 10)
       }}
    end
  end

  defp group_rows_by_agent(resolved_inputs) do
    Enum.reduce(resolved_inputs, %{by_agent: %{}, total_rows: 0}, fn input, acc ->
      name = ValueUtils.string_value(input, [:name, "name"])
      entity = ValueUtils.string_value(input, [:entity, "entity"]) || "unknown"
      query = ValueUtils.string_value(input, [:query, "query"]) || ""
      rows = ValueUtils.list_value(input, [:rows, "rows"]) || []

      Enum.reduce(rows, acc, fn row, input_acc ->
        accumulate_agent_row(input_acc, name, entity, query, MapUtils.stringify_keys(row))
      end)
    end)
  end

  defp accumulate_agent_row(acc, name, entity, query, row) do
    case agent_id_from_row(row) do
      nil ->
        acc

      agent_id ->
        item =
          acc.by_agent
          |> Map.get(agent_id, [])
          |> ensure_input(name, entity, query, row)

        %{
          by_agent: Map.put(acc.by_agent, agent_id, item),
          total_rows: acc.total_rows + 1
        }
    end
  end

  defp assignment_spec(policy, agent_id, payload) do
    input = hd(payload["inputs"])
    key = assignment_key(policy.policy_id, agent_id, input)

    %{
      assignment_key: key,
      agent_uid: agent_id,
      plugin_package_id: policy.plugin_package_id,
      enabled: policy.enabled,
      interval_seconds: policy.interval_seconds,
      timeout_seconds: policy.timeout_seconds,
      params: payload,
      metadata: %{
        "source" => "policy",
        "policy_id" => policy.policy_id,
        "input_name" => input["name"],
        "input_entity" => input["entity"],
        "chunk_index" => input["chunk_index"],
        "chunk_total" => input["chunk_total"],
        "chunk_hash" => input["chunk_hash"]
      }
    }
  end

  defp ensure_input(existing_inputs, name, entity, query, row) do
    case Enum.find_index(existing_inputs, &(&1.name == name)) do
      nil ->
        existing_inputs ++ [%{name: name, entity: entity, query: query, rows: [row]}]

      index ->
        List.update_at(existing_inputs, index, fn input ->
          %{input | rows: input.rows ++ [row]}
        end)
    end
  end

  defp agent_id_from_row(row) do
    ValueUtils.string_value(row, [:agent_uid, "agent_uid", :agent_id, "agent_id"])
  end

  defp assignment_key(policy_id, agent_id, input) do
    payload =
      %{
        policy_id: policy_id,
        agent_id: agent_id,
        input_name: input["name"],
        chunk_index: input["chunk_index"],
        chunk_hash: input["chunk_hash"]
      }
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(payload, case: :lower)
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp required_string(map, keys, label) do
    case ValueUtils.string_value(map, keys) do
      nil -> {:error, ["missing required policy field: #{label}"]}
      "" -> {:error, ["missing required policy field: #{label}"]}
      value -> {:ok, value}
    end
  end

  defp required_positive_int(map, keys, label) do
    case ValueUtils.int_value(map, keys, nil) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _ ->
        {:error, ["missing or invalid required policy field: #{label}"]}
    end
  end
end
