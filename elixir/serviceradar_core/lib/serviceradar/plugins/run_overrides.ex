defmodule ServiceRadar.Plugins.RunOverrides do
  @moduledoc """
  Applies, acknowledges and delivers plugin run overrides
  (`ServiceRadar.Plugins.PluginRunOverride`).

  A plugin action result may carry a `run_overrides` list of operations:

      %{"op" => "set", "id" => "fault-7", "kind" => "channel_saturation",
        "target" => "ap-12", "params" => %{}, "duration_seconds" => 600}
      %{"op" => "end", "id" => "fault-7"}

  `set` may give `starts_at` (default: now) and either `expires_at` or
  `duration_seconds`. The expiry is clamped to the action descriptor's
  `max_override_duration_seconds`; a descriptor without that field may not set
  overrides at all, so a plugin cannot grant itself unbounded state.

  The agent reports, in a plugin result's host-authored
  `run_overrides_acknowledged` list, the expired overrides that a successful run
  received; those stop being delivered.
  """

  alias ServiceRadar.Plugins.PluginRunOverride

  require Ash.Query
  require Logger

  @max_operations_per_result 32
  @schema "serviceradar.plugin_run_overrides.v1"

  @type operation_result :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Wire schema of the per-assignment override list delivered to agents."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Applies the `run_overrides` operations of one action result for the
  assignment that ran the action. Returns the number of operations applied.
  """
  @spec apply_action_result(map(), map(), keyword()) :: operation_result()
  def apply_action_result(payload, context, opts) when is_map(payload) and is_map(context) do
    actor = Keyword.fetch!(opts, :actor)

    case {operations(payload), fetch(context, :plugin_assignment_id)} do
      {[], _} ->
        {:ok, 0}

      {_operations, assignment_id} when not is_binary(assignment_id) or assignment_id == "" ->
        {:error, :missing_plugin_assignment}

      {operations, assignment_id} ->
        max_seconds = Keyword.get(opts, :max_override_duration_seconds)
        invocation_id = Keyword.get(opts, :invocation_id)
        now = Keyword.get(opts, :now, DateTime.utc_now())

        operations
        |> Enum.take(@max_operations_per_result)
        |> Enum.reduce({:ok, 0}, fn operation, {:ok, count} ->
          case apply_operation(
                 operation,
                 assignment_id,
                 invocation_id,
                 max_seconds,
                 now,
                 actor
               ) do
            :ok ->
              {:ok, count + 1}

            {:error, reason} ->
              Logger.warning("Plugin run override operation rejected",
                plugin_assignment_id: assignment_id,
                reason: inspect(reason)
              )

              {:ok, count}
          end
        end)
    end
  end

  def apply_action_result(_payload, _context, _opts), do: {:ok, 0}

  @doc "Marks the given overrides of one assignment acknowledged."
  @spec acknowledge(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def acknowledge(assignment_id, override_ids, opts)
      when is_binary(assignment_id) and is_list(override_ids) do
    actor = Keyword.fetch!(opts, :actor)

    override_ids =
      override_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.take(@max_operations_per_result)

    if override_ids == [] do
      :ok
    else
      PluginRunOverride
      |> Ash.Query.filter(
        plugin_assignment_id == ^assignment_id and override_id in ^override_ids and
          is_nil(acknowledged_at) and expires_at <= now()
      )
      |> Ash.bulk_update(:acknowledge, %{},
        actor: actor,
        strategy: [:atomic, :stream],
        return_errors?: true
      )
      |> bulk_result()
    end
  end

  def acknowledge(_assignment_id, _override_ids, _opts), do: :ok

  @doc """
  Returns `%{assignment_id => [override]}` for every deliverable override of
  the given assignments, each override encoded for the agent.
  """
  @spec deliverable_by_assignment([String.t()], keyword()) :: %{String.t() => [map()]}
  def deliverable_by_assignment([], _opts), do: %{}

  def deliverable_by_assignment(assignment_ids, opts) when is_list(assignment_ids) do
    actor = Keyword.fetch!(opts, :actor)

    case PluginRunOverride.list_deliverable(assignment_ids, actor: actor) do
      {:ok, overrides} ->
        Enum.group_by(overrides, &to_string(&1.plugin_assignment_id), &encode/1)

      {:error, reason} ->
        Logger.warning("Failed to load plugin run overrides", reason: inspect(reason))
        %{}
    end
  end

  @doc "Encodes one assignment's override list as the agent wire JSON."
  @spec encode_list([map()]) :: map()
  def encode_list(overrides) when is_list(overrides) do
    %{"schema" => @schema, "overrides" => overrides}
  end

  defp encode(%PluginRunOverride{} = override) do
    %{
      "id" => override.override_id,
      "kind" => override.kind,
      "target" => override.target,
      "params" => override.params || %{},
      "starts_at" => DateTime.to_iso8601(override.starts_at),
      "expires_at" => DateTime.to_iso8601(override.expires_at)
    }
  end

  defp operations(payload) do
    case fetch(payload, :run_overrides) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp apply_operation(operation, assignment_id, invocation_id, max_seconds, now, actor) do
    case {fetch(operation, :op), fetch(operation, :id)} do
      {_op, id} when not is_binary(id) or id == "" ->
        {:error, :missing_override_id}

      {"end", id} ->
        end_override(assignment_id, id, actor)

      {"set", id} ->
        set_override(operation, id, assignment_id, invocation_id, max_seconds, now, actor)

      {op, _id} ->
        {:error, {:unknown_operation, op}}
    end
  end

  defp set_override(_operation, _id, _assignment_id, _invocation_id, max_seconds, _now, _actor)
       when not is_integer(max_seconds) or max_seconds <= 0 do
    {:error, :descriptor_does_not_allow_overrides}
  end

  defp set_override(operation, id, assignment_id, invocation_id, max_seconds, now, actor) do
    with {:ok, kind} <- required_string(operation, :kind),
         {:ok, starts_at} <- optional_datetime(operation, :starts_at, now),
         {:ok, requested_expiry} <- requested_expiry(operation, starts_at) do
      expires_at =
        Enum.min([requested_expiry, DateTime.shift(starts_at, second: max_seconds)], DateTime)

      attrs = %{
        plugin_assignment_id: assignment_id,
        override_id: id,
        kind: kind,
        target: optional_string(operation, :target),
        params: optional_map(operation, :params),
        starts_at: starts_at,
        expires_at: expires_at,
        invocation_id: invocation_id
      }

      case PluginRunOverride.record(attrs, actor: actor) do
        {:ok, _override} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp end_override(assignment_id, id, actor) do
    PluginRunOverride
    |> Ash.Query.filter(
      plugin_assignment_id == ^assignment_id and override_id == ^id and is_nil(ended_at)
    )
    |> Ash.bulk_update(:end_early, %{},
      actor: actor,
      strategy: [:atomic, :stream],
      return_errors?: true
    )
    |> bulk_result()
  end

  defp requested_expiry(operation, starts_at) do
    case {fetch(operation, :expires_at), fetch(operation, :duration_seconds)} do
      {nil, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, DateTime.shift(starts_at, second: seconds)}

      {value, _} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> {:ok, expires_at}
          _ -> {:error, :invalid_expires_at}
        end

      _ ->
        {:error, :missing_expiry}
    end
  end

  defp required_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp optional_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp optional_map(map, key) do
    case fetch(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp optional_datetime(map, key, default) do
    case fetch(map, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> {:error, {:invalid, key}}
        end

      _ ->
        {:error, {:invalid, key}}
    end
  end

  defp bulk_result(%Ash.BulkResult{status: :success}), do: :ok
  defp bulk_result(%Ash.BulkResult{errors: [error | _]}), do: {:error, error}
  defp bulk_result(%Ash.BulkResult{}), do: {:error, :bulk_update_failed}

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, Atom.to_string(key), Map.get(map, key))
  end
end
