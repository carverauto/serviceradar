defmodule ServiceRadar.Automation.Northbound.Dispatcher do
  @moduledoc """
  Dispatches persisted northbound action invocations to concrete providers.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query
  require Logger

  @command_type "plugin.run_action"

  @spec dispatch_invocation(ActionInvocation.t() | String.t(), keyword()) ::
          {:ok, ActionInvocation.t()} | {:error, term()}
  def dispatch_invocation(invocation_or_id, opts \\ [])

  def dispatch_invocation(%ActionInvocation{} = invocation, opts) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, invocation} <- load_invocation(invocation.id, system_actor),
         :ok <- validate_dispatchable(invocation),
         {:ok, assignment} <- resolve_plugin_assignment(invocation, system_actor),
         {:ok, command} <- dispatch_to_assignment(invocation, assignment, opts, system_actor),
         {:ok, invocation} <-
           mark_invocation_dispatched(invocation, command, assignment, system_actor),
         :ok <- mark_targets_running(invocation, system_actor) do
      {:ok, invocation}
    else
      {:error, reason} ->
        _ = mark_invocation_failed(invocation, reason, system_actor)
        {:error, reason}
    end
  end

  def dispatch_invocation(invocation_id, opts) when is_binary(invocation_id) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, invocation} <- load_invocation(invocation_id, system_actor) do
      dispatch_invocation(invocation, opts)
    end
  end

  def dispatch_invocation(_invocation, _opts), do: {:error, :invalid_invocation}

  defp load_invocation(id, actor) do
    case ActionInvocation.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :invocation_not_found}
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp validate_dispatchable(%ActionInvocation{state: :pending}), do: :ok

  defp validate_dispatchable(%ActionInvocation{state: state}),
    do: {:error, {:not_dispatchable, state}}

  defp resolve_plugin_assignment(%ActionInvocation{provider: provider} = invocation, actor) do
    with :ok <- validate_wasm_provider(provider),
         {:ok, assignments} <- list_package_assignments(provider.plugin_package_id, actor) do
      select_assignment(assignments, preferred_agent_ids(invocation))
    end
  end

  defp validate_wasm_provider(%{provider_type: :wasm_plugin, plugin_package_id: package_id})
       when is_binary(package_id),
       do: :ok

  defp validate_wasm_provider(%{provider_type: provider_type}),
    do: {:error, {:unsupported_provider_type, provider_type}}

  defp validate_wasm_provider(_provider), do: {:error, :provider_not_loaded}

  defp list_package_assignments(plugin_package_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:by_package, %{plugin_package_id: plugin_package_id}, actor: actor)
    |> Ash.read(actor: actor, domain: Plugins)
  end

  defp select_assignment([], _preferred_agent_ids), do: {:error, :no_enabled_plugin_assignment}

  defp select_assignment(assignments, preferred_agent_ids) do
    preferred =
      Enum.find(assignments, fn assignment ->
        assignment.agent_uid in preferred_agent_ids
      end)

    {:ok, preferred || List.first(assignments)}
  end

  defp preferred_agent_ids(%ActionInvocation{target_snapshots: snapshots})
       when is_list(snapshots) do
    snapshots
    |> Enum.flat_map(fn snapshot ->
      [
        map_get(snapshot, "agent_id"),
        map_get(snapshot, "device_agent_id")
      ]
    end)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp preferred_agent_ids(_invocation), do: []

  defp dispatch_to_assignment(invocation, assignment, opts, actor) do
    payload = build_payload(invocation, assignment)
    ttl_seconds = invocation.descriptor.timeout_seconds || assignment.timeout_seconds || 60
    command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

    command_bus.dispatch(
      assignment.agent_uid,
      @command_type,
      payload,
      ttl_seconds: ttl_seconds,
      source: :automation,
      actor: actor,
      context: %{
        northbound_invocation_id: invocation.id,
        northbound_descriptor_id: invocation.descriptor_id,
        northbound_provider_id: invocation.provider_id,
        plugin_assignment_id: assignment.id,
        plugin_package_id: assignment.plugin_package_id,
        action_id: invocation.action_id
      }
    )
  end

  defp build_payload(invocation, assignment) do
    %{
      "schema" => "serviceradar.northbound_action_invocation.v1",
      "invocation_id" => invocation.id,
      "provider_id" => invocation.provider_id,
      "descriptor_id" => invocation.descriptor_id,
      "action_id" => invocation.action_id,
      "action_version" => invocation.action_version,
      "descriptor_hash" => invocation.descriptor_hash,
      "result_schema_version" => invocation.descriptor.result_schema_version,
      "plugin_assignment_id" => assignment.id,
      "plugin_package_id" => assignment.plugin_package_id,
      "targets" => invocation.target_snapshots || [],
      "input_values" => invocation.input_values || %{},
      "redacted_input_values" => invocation.redacted_input_values || %{},
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "metadata" => Map.put(invocation.metadata || %{}, "dispatch_agent_id", assignment.agent_uid)
    }
  end

  defp mark_invocation_dispatched(invocation, command, assignment, actor) do
    metadata =
      invocation.metadata
      |> normalize_map()
      |> Map.merge(%{
        "agent_command_id" => command_id(command),
        "dispatch_agent_id" => assignment.agent_uid,
        "plugin_assignment_id" => assignment.id
      })

    ActionInvocation.record_dispatch(invocation, %{metadata: metadata}, actor: actor)
  end

  defp mark_targets_running(invocation, actor) do
    now = DateTime.utc_now()

    invocation.id
    |> list_targets(actor)
    |> Enum.each(fn target ->
      _ =
        ActionInvocationTarget.record_result(target, %{status: :running, started_at: now},
          actor: actor
        )
    end)

    :ok
  end

  defp mark_invocation_failed(%ActionInvocation{} = invocation, reason, actor) do
    _ =
      ActionInvocation.record_failed(
        invocation,
        %{
          error_class: "dispatch_failed",
          error_message: inspect(reason),
          result_summary: %{"status" => "failed", "reason" => inspect(reason)}
        },
        actor: actor
      )

    now = DateTime.utc_now()

    invocation.id
    |> list_targets(actor)
    |> Enum.each(fn target ->
      _ =
        ActionInvocationTarget.record_result(
          target,
          %{status: :failed, completed_at: now, result: %{"reason" => inspect(reason)}},
          actor: actor
        )
    end)
  end

  defp mark_invocation_failed(_invocation, _reason, _actor), do: :ok

  defp list_targets(invocation_id, actor) do
    case ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp command_id(%{id: id}), do: id
  defp command_id(%{command_id: id}), do: id
  defp command_id(command), do: inspect(command)

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil
end
