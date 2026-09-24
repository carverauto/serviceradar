defmodule ServiceRadarWebNGWeb.DeviceLive.MtrRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  require Logger

  @default_page_size 50
  @max_page_size 200
  @unexpected_error_message "MTR could not be queued because of an unexpected error"

  def get_trace_detail(scope, trace_id, opts \\ []), do: MtrData.get_trace_detail(scope, trace_id, opts)

  @doc """
  Queues an ad-hoc MTR trace for the device page's Queue MTR button.

  Returns `{:ok, agent_id}` or `{:error, message}` with an operator-readable
  message, and never raises: a fault anywhere in policy lookup or dispatch is
  logged and reported as an error, so it cannot take the device LiveView down.

  The collaborators are injectable for tests (`:list_policies`,
  `:dispatch_policy`, `:list_agents`, `:dispatch_command`); each defaults to
  the real function.
  """
  @spec queue_trace(Phoenix.LiveView.Socket.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def queue_trace(socket, device_ip, opts \\ []) do
    with :ok <- validate_device_ip(device_ip) do
      deps = dispatch_deps(opts)
      target_ctx = build_mtr_target_ctx(socket, device_ip)

      case dispatch_with_automation_policy(target_ctx, deps) do
        {:ok, [agent_id | _]} ->
          {:ok, agent_id}

        {:error, {:window_persist_failed, _} = reason} ->
          # The policy's mtr.run commands were accepted; only the cooldown row
          # failed to save. Dispatching directly now would queue a second trace.
          Logger.warning("[MtrRuntime] MTR policy dispatched but #{inspect(reason)}")
          {:ok, "the policy-selected agents"}

        {:error, policy_reason} ->
          # Queue MTR is an operator request, and an automation policy only picks
          # the vantage when one applies. A policy that cannot dispatch (none
          # enabled, out of scope, in cooldown, no candidate online) therefore
          # still falls back to the first connected agent, as it did before
          # policies were consulted here.
          dispatch_directly(socket, device_ip, policy_reason, deps)
      end
    end
  rescue
    error ->
      Logger.error(
        "[MtrRuntime] Queue MTR raised for #{inspect(device_ip)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, @unexpected_error_message}
  catch
    :exit, reason ->
      Logger.error("[MtrRuntime] Queue MTR exited for #{inspect(device_ip)}: #{inspect(reason)}")
      {:error, @unexpected_error_message}
  end

  @doc """
  Maps an MTR dispatcher or command-bus error reason to an operator-readable
  message.
  """
  @spec dispatch_error_message(term()) :: String.t()
  def dispatch_error_message(reason)

  def dispatch_error_message(reason) when reason in [:no_enabled_policy, :no_matching_policy],
    do: "No MTR policy applies to this device"

  def dispatch_error_message(:policy_lookup_failed), do: "MTR policies could not be loaded"

  def dispatch_error_message(:policy_dispatch_failed), do: "The MTR policy dispatch failed unexpectedly"

  def dispatch_error_message(:out_of_scope), do: "The device is outside the MTR policy's scope"

  def dispatch_error_message(:no_candidates), do: "No MTR-capable agent is online in the device's partition"

  def dispatch_error_message(:preferred_agent_unavailable), do: "The MTR policy's preferred agent is not online"

  def dispatch_error_message(:cooldown_active),
    do: "An automated MTR trace for this device ran recently and is in cooldown"

  def dispatch_error_message(:no_selected_agents), do: "The MTR policy selected no agent"

  def dispatch_error_message(:dispatch_failed), do: "Every agent the MTR policy selected rejected the trace"

  def dispatch_error_message({:window_persist_failed, _reason}),
    do: "The MTR trace was dispatched, but its cooldown window could not be saved"

  def dispatch_error_message(reason) when reason in [:missing_target, :invalid_target_context],
    do: "No device IP available for MTR"

  def dispatch_error_message({:agent_busy, :too_many_concurrent_mtr_traces}),
    do: "Agent is already running the maximum number of concurrent MTR traces"

  def dispatch_error_message(:agent_offline), do: "The agent is offline"

  def dispatch_error_message({:agent_offline, agent_id}), do: "Agent #{agent_id} is offline"

  def dispatch_error_message({:agent_capability_missing, agent_id, capability}),
    do: "Agent #{agent_id} does not support #{capability}"

  def dispatch_error_message({:agent_partition_mismatch, agent_id, _partition}),
    do: "Agent #{agent_id} is not in the device's partition"

  def dispatch_error_message({:agent_partition_ambiguous, agent_id}),
    do: "Agent #{agent_id} is connected in more than one partition"

  def dispatch_error_message(:registry_unavailable), do: "The agent registry is unavailable; try again shortly"

  def dispatch_error_message(:control_session_unavailable), do: "The agent's control session is unavailable"

  def dispatch_error_message({:control_session_exit, _reason}), do: "The agent's control session is unavailable"

  def dispatch_error_message(reason), do: "Failed to run MTR: #{inspect(reason)}"

  def refresh_if_relevant(socket, msg, device_ip) when is_map(msg) do
    device_uid = socket.assigns.device_uid
    msg_device_uid = mtr_msg_device_uid(msg)
    msg_target_ip = mtr_msg_target_ip(msg)

    if msg_matches_device?(msg_device_uid, device_uid) or
         msg_matches_device?(msg_target_ip, device_ip) do
      maybe_refresh_tab(socket, device_ip)
    else
      socket
    end
  end

  def refresh_if_relevant(socket, _msg, _device_ip), do: socket

  def load_traces(socket, device_ip) do
    device_uid = socket.assigns.device_uid

    if is_nil(device_uid) and is_nil(device_ip) do
      socket
      |> assign(:mtr_traces, [])
      |> assign(:mtr_recent_traces, [])
      |> assign(:mtr_pending_jobs, [])
      |> assign(:mtr_trends, %{hops: [], latency: []})
      |> assign(:mtr_total_count, 0)
      |> assign(:mtr_coverage, %{trace_count: 0, earliest_time: nil, latest_time: nil})
      |> assign(:mtr_retention_status, MtrData.retention_status(socket.assigns.current_scope))
    else
      page = Map.get(socket.assigns, :mtr_page, 1)
      page_size = Map.get(socket.assigns, :mtr_page_size, default_page_size())

      traces_result =
        MtrData.list_traces_paginated(
          device_uid: device_uid,
          device_ip: device_ip,
          limit: page_size,
          page: page
        )

      recent_traces_result = MtrData.list_traces(device_uid: device_uid, device_ip: device_ip, limit: 50)

      coverage_result = MtrData.trace_coverage(device_uid: device_uid, device_ip: device_ip)

      pending_result =
        MtrData.list_pending_jobs(socket.assigns.current_scope,
          device_uid: device_uid,
          device_ip: device_ip
        )

      traces =
        case traces_result do
          {:ok, %{rows: rows}} -> rows
          _ -> []
        end

      total_count =
        case traces_result do
          {:ok, %{total_count: total}} -> total || 0
          _ -> 0
        end

      recent_traces =
        case recent_traces_result do
          {:ok, rows} -> rows
          _ -> []
        end

      coverage =
        case coverage_result do
          {:ok, value} -> value
          _ -> %{trace_count: total_count, earliest_time: nil, latest_time: nil}
        end

      pending_jobs =
        case pending_result do
          {:ok, rows} -> rows
          _ -> []
        end

      pending_jobs = MtrData.suppress_completed_pending_jobs(pending_jobs, recent_traces)

      socket
      |> assign(:mtr_traces, traces)
      |> assign(:mtr_recent_traces, recent_traces)
      |> assign(:mtr_total_count, total_count)
      |> assign(:mtr_coverage, coverage)
      |> assign(:mtr_retention_status, MtrData.retention_status(socket.assigns.current_scope))
      |> assign(:mtr_pending_jobs, pending_jobs)
      |> assign(:mtr_trends, MtrData.build_trends(recent_traces))
    end
  end

  def detect_available(scope, device_uid, device_ip) do
    traces? =
      case MtrData.list_traces(device_uid: device_uid, device_ip: device_ip, limit: 1) do
        {:ok, [_ | _]} -> true
        _ -> false
      end

    pending? =
      case MtrData.list_pending_jobs(scope, device_uid: device_uid, device_ip: device_ip) do
        {:ok, [_ | _]} -> true
        _ -> false
      end

    traces? or pending?
  rescue
    _ -> false
  end

  defp maybe_refresh_tab(socket, device_ip) do
    if socket.assigns.active_tab == "mtr" do
      load_traces(socket, device_ip)
    else
      socket
    end
  end

  defp validate_device_ip(device_ip) when is_binary(device_ip) and device_ip != "", do: :ok
  defp validate_device_ip(_), do: {:error, "No device IP available for MTR"}

  defp dispatch_deps(opts) do
    %{
      list_policies: Keyword.get(opts, :list_policies, &MtrPolicy.list_enabled/0),
      dispatch_policy: Keyword.get(opts, :dispatch_policy, &MtrAutomationDispatcher.dispatch_for_mode/3),
      list_agents: Keyword.get(opts, :list_agents, &AgentCommandBus.list_online_agents/0),
      dispatch_command: Keyword.get(opts, :dispatch_command, &AgentCommandBus.dispatch/4)
    }
  end

  defp dispatch_directly(socket, device_ip, policy_reason, deps) do
    maybe_log_policy_fallback(policy_reason)

    result =
      with {:ok, agent_id} <- first_connected_agent_id(deps) do
        dispatch_direct_mtr_trace(socket, agent_id, device_ip, deps)
      end

    case result do
      {:ok, _agent_id} = ok -> ok
      {:error, message} -> {:error, with_policy_context(message, policy_reason)}
    end
  end

  defp maybe_log_policy_fallback(reason) when reason in [:no_enabled_policy, :no_matching_policy], do: :ok

  defp maybe_log_policy_fallback(reason) do
    Logger.info("[MtrRuntime] MTR policy did not dispatch (#{inspect(reason)}); dispatching directly")
  end

  # When the direct fallback fails too, say why the policy did not dispatch as
  # well, unless no policy applied at all.
  defp with_policy_context(message, reason) when reason in [:no_enabled_policy, :no_matching_policy], do: message

  defp with_policy_context(message, reason), do: "#{message} (MTR policy: #{dispatch_error_message(reason)})"

  defp first_connected_agent_id(deps) do
    case list_connected_agents(deps) do
      [first | _] ->
        agent_id = Map.get(first, :agent_id) || Map.get(first, "agent_id")

        if is_binary(agent_id) and String.trim(agent_id) != "" do
          {:ok, agent_id}
        else
          {:error, "Connected agent is missing an agent_id"}
        end

      [] ->
        {:error, "No agents connected"}
    end
  end

  defp list_connected_agents(deps) do
    deps.list_agents.()
  rescue
    _ -> []
  end

  defp dispatch_direct_mtr_trace(socket, agent_id, device_ip, deps) do
    payload = %{"target" => device_ip, "protocol" => "icmp"}
    context = %{"device_uid" => socket.assigns.device_uid, "target_ip" => device_ip}

    case deps.dispatch_command.(agent_id, "mtr.run", payload, context: context) do
      {:ok, _command_id} -> {:ok, agent_id}
      {:error, reason} -> {:error, dispatch_error_message(reason)}
    end
  end

  defp dispatch_with_automation_policy(target_ctx, deps) do
    case deps.list_policies.() do
      {:ok, policies} when is_list(policies) ->
        dispatch_with_first_matching_policy(policies, target_ctx, deps, [])

      {:error, reason} ->
        Logger.warning("[MtrRuntime] Listing enabled MTR policies failed: #{inspect(reason)}")
        {:error, :policy_lookup_failed}

      _ ->
        {:error, :no_enabled_policy}
    end
  end

  defp dispatch_with_first_matching_policy([], _target_ctx, _deps, reasons), do: {:error, policy_failure_reason(reasons)}

  defp dispatch_with_first_matching_policy([policy | rest], target_ctx, deps, reasons) do
    policy =
      policy
      |> Map.put_new(:baseline_canary_vantages, 0)
      |> Map.put_new("baseline_canary_vantages", 0)

    case dispatch_policy(target_ctx, policy, deps) do
      {:ok, [_ | _] = selected_agents} ->
        {:ok, selected_agents}

      # Commands already went out; trying the next policy would trace again.
      {:error, {:window_persist_failed, _}} = error ->
        error

      {:error, reason} ->
        dispatch_with_first_matching_policy(rest, target_ctx, deps, [reason | reasons])

      _no_agents ->
        dispatch_with_first_matching_policy(rest, target_ctx, deps, [:no_selected_agents | reasons])
    end
  end

  # The first policy (in list order) that applied to the device but could not
  # dispatch explains the outcome better than one whose scope excluded it.
  defp policy_failure_reason(reasons) do
    reasons
    |> Enum.reverse()
    |> Enum.find(:no_matching_policy, &(&1 != :out_of_scope))
  end

  # A policy dispatch that raises must not take the device LiveView down with
  # it; log it and let the caller fall through to the next policy and finally
  # the direct-dispatch path.
  defp dispatch_policy(target_ctx, policy, deps) do
    deps.dispatch_policy.(target_ctx, policy, :baseline)
  rescue
    error ->
      Logger.warning(
        "[MtrRuntime] MTR policy dispatch raised for policy #{inspect(Map.get(policy, :id))}: " <>
          Exception.message(error)
      )

      {:error, :policy_dispatch_failed}
  end

  defp build_mtr_target_ctx(socket, target_ip) do
    device_row = socket.assigns[:device_row] || %{}
    partition_id = device_row["partition"] || device_row["partition_id"] || "default"

    %{
      target: target_ip,
      target_ip: target_ip,
      target_device_uid: socket.assigns.device_uid,
      partition_id: partition_id,
      gateway_id: device_row["gateway_id"],
      target_key: "device:#{socket.assigns.device_uid}"
    }
  end

  defp mtr_msg_device_uid(msg) do
    context = map_get_any(msg, [:context, "context"], %{})
    map_get_any(context, [:device_uid, "device_uid"], nil)
  end

  defp mtr_msg_target_ip(msg) do
    context = map_get_any(msg, [:context, "context"], %{})
    payload = map_get_any(msg, [:payload, "payload"], %{})
    trace = map_get_any(payload, [:trace, "trace"], %{})

    map_get_any(context, [:target_ip, "target_ip"], nil) ||
      map_get_any(msg, [:target, "target", :target_ip, "target_ip"], nil) ||
      map_get_any(payload, [:target, "target"], nil) ||
      map_get_any(trace, [:target_ip, "target_ip", :target, "target"], nil)
  end

  defp msg_matches_device?(candidate, expected) when is_binary(candidate) and is_binary(expected) do
    candidate = String.trim(candidate)
    expected = String.trim(expected)

    candidate != "" and candidate == expected
  end

  defp msg_matches_device?(_, _), do: false

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  def default_page_size do
    MtrSettingsRuntime.settings()
    |> Map.get(:mtr_history_page_size_default, @default_page_size)
    |> parse_limit(@default_page_size, @max_page_size)
  rescue
    _ -> @default_page_size
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  defp parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  defp parse_limit(_limit, default, _max), do: default
end
