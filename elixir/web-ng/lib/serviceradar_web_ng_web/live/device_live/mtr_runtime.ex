defmodule ServiceRadarWebNGWeb.DeviceLive.MtrRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  @default_page_size 50
  @max_page_size 200

  def get_trace_detail(scope, trace_id), do: MtrData.get_trace_detail(scope, trace_id)

  def queue_trace(socket, device_ip) do
    with :ok <- validate_device_ip(device_ip) do
      target_ctx = build_mtr_target_ctx(socket, device_ip)

      case dispatch_with_automation_policy(target_ctx) do
        {:ok, [agent_id | _]} ->
          {:ok, agent_id}

        {:error, _} ->
          with {:ok, agent_id} <- first_connected_agent_id() do
            dispatch_direct_mtr_trace(socket, agent_id, device_ip)
          end
      end
    end
  end

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

  defp first_connected_agent_id do
    case list_connected_agents() do
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

  defp list_connected_agents do
    AgentCommandBus.list_online_agents()
  rescue
    _ -> []
  end

  defp dispatch_direct_mtr_trace(socket, agent_id, device_ip) do
    payload = %{"target" => device_ip, "protocol" => "icmp"}
    context = %{"device_uid" => socket.assigns.device_uid, "target_ip" => device_ip}

    case AgentCommandBus.dispatch(agent_id, "mtr.run", payload, context: context) do
      {:ok, _command_id} ->
        {:ok, agent_id}

      {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} ->
        {:error, "Agent is already running the maximum number of concurrent MTR traces"}

      {:error, reason} ->
        {:error, "Failed to run MTR: #{inspect(reason)}"}
    end
  end

  defp dispatch_with_automation_policy(target_ctx) do
    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        dispatch_with_first_matching_policy(policies, target_ctx)

      _ ->
        {:error, :no_enabled_policy}
    end
  end

  defp dispatch_with_first_matching_policy([], _target_ctx), do: {:error, :no_matching_policy}

  defp dispatch_with_first_matching_policy([policy | rest], target_ctx) do
    policy =
      policy
      |> Map.put_new(:baseline_canary_vantages, 0)
      |> Map.put_new("baseline_canary_vantages", 0)

    case MtrAutomationDispatcher.dispatch_for_mode(target_ctx, policy, :baseline) do
      {:ok, selected_agents} when is_list(selected_agents) and selected_agents != [] ->
        {:ok, selected_agents}

      _ ->
        dispatch_with_first_matching_policy(rest, target_ctx)
    end
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
