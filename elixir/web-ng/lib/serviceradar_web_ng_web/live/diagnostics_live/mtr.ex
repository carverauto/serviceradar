defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @command_type_mtr_run "mtr.run"
  @command_type_mtr_bulk_run "mtr.bulk_run"
  @protocol_icmp "icmp"
  @protocol_udp "udp"
  @protocol_tcp "tcp"
  @protocols [@protocol_icmp, @protocol_udp, @protocol_tcp]
  @execution_profile_fast "fast"
  @execution_profile_balanced "balanced"
  @execution_profile_deep "deep"
  @execution_profiles [
    @execution_profile_fast,
    @execution_profile_balanced,
    @execution_profile_deep
  ]
  @payload_target_key "target"
  @payload_targets_key "targets"
  @payload_agent_id_key "agent_id"
  @payload_elapsed_ms_key "elapsed_ms"
  @payload_target_ip_key "target_ip"
  @payload_check_name_key "check_name"
  @payload_ip_version_key "ip_version"
  @payload_targets_per_minute_key "targets_per_minute"
  @payload_duration_ms_key "duration_ms"
  @payload_concurrency_key "concurrency"
  @payload_max_concurrency_key "max_concurrency"
  @payload_concurrency_history_key "concurrency_history"
  @payload_total_targets_key "total_targets"
  @payload_completed_targets_key "completed_targets"
  @payload_failed_targets_key "failed_targets"
  @payload_running_targets_key "running_targets"
  @payload_timed_out_targets_key "timed_out_targets"
  @payload_protocol_key "protocol"
  @payload_execution_profile_key "execution_profile"
  @payload_target_query_key "target_query"
  @payload_selector_limit_key "selector_limit"

  @default_limit 25
  @max_limit 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, MtrPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "MTR Diagnostics")
     |> assign(:page_path, "/diagnostics/mtr")
     |> assign(:last_params, %{})
     |> assign(:last_uri, "/diagnostics/mtr")
     |> assign(:traces, [])
     |> assign(:pending_jobs, [])
     |> assign(:bulk_jobs, [])
     |> assign(:limit, @default_limit)
     |> assign(:current_page, 1)
     |> assign(:total_count, 0)
     |> assign(:filter_target, "")
     |> assign(:filter_agent, "")
     # On-demand MTR modal state
     |> assign(:show_mtr_modal, false)
     |> assign(:mtr_agents, [])
     |> assign(
       :mtr_form,
       to_form(
         %{
           @payload_target_key => "",
           @payload_agent_id_key => "",
           @payload_protocol_key => @protocol_icmp
         },
         as: :mtr
       )
     )
     |> assign(:mtr_running, false)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_command_id, nil)
     |> assign(:show_bulk_mtr_modal, false)
     |> assign(
       :bulk_mtr_form,
       to_form(
         %{
           @payload_targets_key => "",
           @payload_target_query_key => "",
           @payload_selector_limit_key => "100",
           @payload_agent_id_key => "",
           @payload_protocol_key => @protocol_icmp,
           @payload_execution_profile_key => @execution_profile_fast,
           @payload_concurrency_key => "64"
         },
         as: :bulk_mtr
       )
     )
     |> assign(:bulk_mtr_error, nil)
     |> assign(:refresh_timer, nil)
     |> SRQLPage.init("mtr_traces", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:last_params, params)
      |> assign(:last_uri, uri)
      |> assign(:filter_target, normalize_text(Map.get(params, "target")))
      |> assign(:filter_agent, normalize_text(Map.get(params, "agent")))
      |> assign(:current_page, parse_page(Map.get(params, "page")))
      |> assign(:limit, parse_limit(Map.get(params, "limit"), @default_limit))
      |> sync_srql_state(params, uri)

    {:noreply, refresh_diagnostics(socket)}
  end

  @impl true
  def handle_event("filter", %{"target" => target, "agent" => agent}, socket) do
    params =
      socket.assigns
      |> Map.get(:last_params, %{})
      |> Map.merge(%{
        "target" => normalize_text(target),
        "agent" => normalize_text(agent),
        "page" => 1
      })
      |> Map.put("limit", socket.assigns.limit)
      |> maybe_put_query(socket.assigns.srql[:query] || "")

    {:noreply, push_patch(socket, to: patch_path(params))}
  end

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, opts)}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "mtr_traces")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, opts)}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "mtr_traces")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "mtr_traces")}
  end

  def handle_event("open_mtr_modal", _params, socket) do
    agents =
      try do
        AgentRegistry.find_agents()
      rescue
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:show_mtr_modal, true)
     |> assign(:mtr_agents, agents)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_running, false)}
  end

  def handle_event("close_mtr_modal", _params, socket) do
    {:noreply, assign(socket, :show_mtr_modal, false)}
  end

  def handle_event("open_bulk_mtr_modal", _params, socket) do
    agents =
      try do
        AgentRegistry.find_agents()
      rescue
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:show_bulk_mtr_modal, true)
     |> assign(:mtr_agents, agents)
     |> assign(:bulk_mtr_error, nil)}
  end

  def handle_event("close_bulk_mtr_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_mtr_modal, false)}
  end

  def handle_event("run_mtr", %{"mtr" => mtr_params}, socket) do
    target = String.trim(mtr_params[@payload_target_key] || "")
    agent_id = mtr_params[@payload_agent_id_key] || ""
    protocol = normalize_protocol(Map.get(mtr_params, @payload_protocol_key, @protocol_icmp))

    cond do
      target == "" ->
        {:noreply, assign(socket, :mtr_error, "Target is required")}

      agent_id == "" ->
        {:noreply, assign(socket, :mtr_error, "Please select an agent")}

      true ->
        payload = %{@payload_target_key => target, @payload_protocol_key => protocol}

        case AgentCommandBus.dispatch(agent_id, @command_type_mtr_run, payload, required_capability: "mtr") do
          {:ok, command_id} ->
            {:noreply,
             socket
             |> assign(:show_mtr_modal, false)
             |> assign(:mtr_running, true)
             |> assign(:mtr_error, nil)
             |> assign(:mtr_command_id, command_id)
             |> put_flash(:info, "MTR trace queued")
             |> refresh_diagnostics()}

          {:error, {:agent_offline, _}} ->
            {:noreply, assign(socket, :mtr_error, "Agent is offline")}

          {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} ->
            {:noreply,
             assign(
               socket,
               :mtr_error,
               "Agent is already running the maximum number of concurrent MTR traces"
             )}

          {:error, reason} ->
            {:noreply, assign(socket, :mtr_error, "Failed to dispatch: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("run_again", %{"target" => target, "agent_id" => agent_id} = params, socket) do
    protocol = normalize_protocol(Map.get(params, @payload_protocol_key, @protocol_icmp))
    payload = %{@payload_target_key => target, @payload_protocol_key => protocol}

    case AgentCommandBus.dispatch(agent_id, @command_type_mtr_run, payload, required_capability: "mtr") do
      {:ok, command_id} ->
        {:noreply,
         socket
         |> assign(:mtr_command_id, command_id)
         |> put_flash(:info, "MTR trace queued")
         |> refresh_diagnostics()}

      {:error, {:agent_offline, _}} ->
        {:noreply, put_flash(socket, :error, "Agent is offline")}

      {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Agent is already running the maximum number of concurrent MTR traces"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dispatch: #{inspect(reason)}")}
    end
  end

  def handle_event("run_bulk_mtr", %{"bulk_mtr" => params}, socket) do
    socket =
      assign(socket, :bulk_mtr_form, to_form(normalize_bulk_mtr_params(params), as: :bulk_mtr))

    agent_id = params[@payload_agent_id_key] || ""
    protocol = normalize_protocol(Map.get(params, @payload_protocol_key, @protocol_icmp))

    execution_profile =
      normalize_bulk_execution_profile(Map.get(params, @payload_execution_profile_key, @execution_profile_fast))

    concurrency = parse_positive_integer(Map.get(params, "concurrency"), 64)
    selector_limit = parse_positive_integer(Map.get(params, @payload_selector_limit_key), 100)

    with :ok <- validate_bulk_mtr_agent(agent_id),
         {:ok, targets} <- bulk_targets_from_params(params, selector_limit),
         {:ok, _command_id} <-
           AgentCommandBus.dispatch_bulk_mtr(agent_id, targets,
             protocol: protocol,
             execution_profile: execution_profile,
             concurrency: concurrency,
             target_query: bulk_target_query(params),
             selector_limit: selector_limit
           ) do
      {:noreply,
       socket
       |> assign(:show_bulk_mtr_modal, false)
       |> assign(:bulk_mtr_error, nil)
       |> put_flash(:info, "Bulk MTR job queued for #{length(targets)} targets")
       |> refresh_diagnostics()}
    else
      {:error, :missing_targets} ->
        {:noreply,
         assign(
           socket,
           :bulk_mtr_error,
           "Provide at least one target or an SRQL query"
         )}

      {:error, :missing_agent} ->
        {:noreply, assign(socket, :bulk_mtr_error, "Please select an agent")}

      {:error, :empty_srql_targets} ->
        {:noreply, assign(socket, :bulk_mtr_error, "SRQL query returned no eligible targets")}

      {:error, {:srql_query_failed, reason}} ->
        {:noreply, assign(socket, :bulk_mtr_error, "SRQL target resolution failed: #{inspect(reason)}")}

      {:error, {:agent_busy, :bulk_mtr_job_running}} ->
        {:noreply, assign(socket, :bulk_mtr_error, "Agent already has a bulk MTR job in progress")}

      {:error, {:agent_offline, _}} ->
        {:noreply, assign(socket, :bulk_mtr_error, "Agent is offline")}

      {:error, reason} ->
        {:noreply, assign(socket, :bulk_mtr_error, "Failed to dispatch bulk job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:command_result, %{command_type: @command_type_mtr_run} = msg}, socket) do
    command_id = Map.get(msg, :command_id) || Map.get(msg, "command_id")

    socket =
      if active_mtr_command?(socket, command_id) do
        socket
        |> assign(:mtr_running, false)
        |> assign(:mtr_command_id, nil)
      else
        socket
      end

    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:mtr_trace_ingested, _event}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:command_ack, %{command_type: @command_type_mtr_run}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:command_progress, %{command_type: @command_type_mtr_run}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:command_ack, %{command_type: @command_type_mtr_bulk_run}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:command_progress, %{command_type: @command_type_mtr_bulk_run}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:command_result, %{command_type: @command_type_mtr_bulk_run}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(:refresh_diagnostics, socket) do
    {:noreply,
     socket
     |> assign(:refresh_timer, nil)
     |> refresh_diagnostics()}
  end

  def handle_info({:command_result, _}, socket), do: {:noreply, socket}
  def handle_info({:command_ack, _}, socket), do: {:noreply, socket}
  def handle_info({:command_progress, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp active_mtr_command?(socket, command_id) when is_binary(command_id) and command_id != "" do
    current_command_id = socket.assigns[:mtr_command_id]
    is_binary(current_command_id) and current_command_id == command_id
  end

  defp active_mtr_command?(_socket, _command_id), do: false

  defp normalize_protocol(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in @protocols do
      value
    else
      @protocol_icmp
    end
  end

  defp normalize_bulk_execution_profile(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in @execution_profiles do
      value
    else
      @execution_profile_fast
    end
  end

  defp normalize_bulk_mtr_params(params) when is_map(params) do
    %{
      "targets" => to_string(Map.get(params, @payload_targets_key, "")),
      @payload_target_query_key => to_string(Map.get(params, @payload_target_query_key, "")),
      @payload_selector_limit_key => to_string(Map.get(params, @payload_selector_limit_key, "100")),
      "agent_id" => to_string(Map.get(params, @payload_agent_id_key, "")),
      @payload_protocol_key => normalize_protocol(Map.get(params, @payload_protocol_key, @protocol_icmp)),
      @payload_execution_profile_key =>
        normalize_bulk_execution_profile(Map.get(params, @payload_execution_profile_key, @execution_profile_fast)),
      "concurrency" => to_string(Map.get(params, @payload_concurrency_key, "64"))
    }
  end

  defp manual_bulk_targets(params) when is_map(params) do
    params
    |> Map.get("targets", "")
    |> to_string()
    |> String.split(~r/[\r\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp bulk_targets_from_params(params, selector_limit) when is_map(params) and is_integer(selector_limit) do
    query =
      params
      |> Map.get(@payload_target_query_key, "")
      |> to_string()
      |> String.trim()

    case query do
      "" ->
        params
        |> manual_bulk_targets()
        |> wrap_manual_bulk_targets()

      _ ->
        query
        |> MtrAutomationDispatcher.target_contexts_from_srql(selector_limit)
        |> wrap_srql_bulk_targets()
    end
  end

  defp bulk_target_from_ctx(target_ctx) when is_map(target_ctx) do
    target =
      Map.get(target_ctx, :target) ||
        Map.get(target_ctx, "target") ||
        Map.get(target_ctx, :target_ip) ||
        Map.get(target_ctx, "target_ip")

    normalize_text(target)
  end

  defp bulk_target_from_ctx(_), do: nil

  defp bulk_target_query(params) when is_map(params) do
    params
    |> Map.get(@payload_target_query_key, "")
    |> normalize_text()
  end

  defp validate_bulk_mtr_agent(""), do: {:error, :missing_agent}
  defp validate_bulk_mtr_agent(nil), do: {:error, :missing_agent}
  defp validate_bulk_mtr_agent(_agent_id), do: :ok

  defp parse_positive_integer(nil, default), do: default

  defp parse_positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp bulk_count(job, key, default) do
    payload = job.result_payload || job.progress_payload || %{}
    Map.get(payload, key, default)
  end

  defp count_targets(job) do
    job
    |> Map.get(:payload, %{})
    |> Map.get("targets", [])
    |> List.wrap()
    |> length()
  end

  defp bulk_rate(job) do
    payload = job.result_payload || job.progress_payload || %{}

    case Map.get(payload, @payload_targets_per_minute_key) do
      value when is_float(value) -> "#{Float.round(value, 1)} targets/min"
      value when is_integer(value) -> "#{value}.0 targets/min"
      value when is_binary(value) -> "#{value} targets/min"
      _ -> "-"
    end
  end

  defp bulk_rate_value(job) do
    payload = job.result_payload || job.progress_payload || %{}
    extract_float_metric(payload, @payload_targets_per_minute_key) || 0.0
  end

  defp bulk_duration(job) do
    payload = job.result_payload || job.progress_payload || %{}

    case Map.get(payload, @payload_duration_ms_key) do
      value when is_integer(value) and value > 0 ->
        "#{div(value, 1000)}s"

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> "#{div(parsed, 1000)}s"
          _ -> "-"
        end

      _ ->
        "-"
    end
  end

  defp bulk_concurrency(job) do
    payload = job.result_payload || job.progress_payload || %{}

    current = Map.get(payload, @payload_concurrency_key)
    max = Map.get(payload, @payload_max_concurrency_key)

    case {current, max} do
      {curr, maxc} when is_integer(curr) and is_integer(maxc) and maxc > 0 and curr != maxc ->
        "#{curr}/#{maxc}"

      {curr, maxc} when is_integer(curr) and is_integer(maxc) and maxc > 0 ->
        "#{curr}"

      {curr, _} when is_integer(curr) ->
        "#{curr}"

      _ ->
        "-"
    end
  end

  defp bulk_timeout_count(job) do
    bulk_count(job, @payload_timed_out_targets_key, 0)
  end

  defp bulk_success_rate(job) do
    total_targets = bulk_count(job, @payload_total_targets_key, count_targets(job))
    completed_targets = bulk_count(job, @payload_completed_targets_key, 0)
    Float.round(safe_ratio(completed_targets, total_targets) * 100, 1)
  end

  defp bulk_mix(job) do
    total_targets = bulk_count(job, @payload_total_targets_key, count_targets(job))
    completed_targets = bulk_count(job, @payload_completed_targets_key, 0)
    failed_targets = bulk_count(job, @payload_failed_targets_key, 0)
    timed_out_targets = bulk_timeout_count(job)
    error_targets = max(failed_targets - timed_out_targets, 0)

    %{
      total_targets: total_targets,
      completed_targets: completed_targets,
      timed_out_targets: timed_out_targets,
      error_targets: error_targets
    }
  end

  defp bulk_concurrency_history(job) do
    payload = job.result_payload || job.progress_payload || %{}

    payload
    |> Map.get(@payload_concurrency_history_key, [])
    |> List.wrap()
    |> Enum.map(fn
      %{} = sample ->
        %{
          elapsed_ms: extract_int_metric(sample, @payload_elapsed_ms_key) || 0,
          concurrency: extract_int_metric(sample, @payload_concurrency_key) || 0,
          max_concurrency: extract_int_metric(sample, @payload_max_concurrency_key) || 0
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp bulk_throttled?(job) do
    payload = job.result_payload || job.progress_payload || %{}
    history = bulk_concurrency_history(job)

    if history == [] do
      current = Map.get(payload, @payload_concurrency_key)
      max = Map.get(payload, @payload_max_concurrency_key)
      is_integer(current) and is_integer(max) and max > current
    else
      Enum.any?(history, fn sample ->
        sample.max_concurrency > 0 and sample.concurrency < sample.max_concurrency
      end)
    end
  end

  defp bulk_job_query(job) do
    job
    |> Map.get(:payload, %{})
    |> Map.get(@payload_target_query_key)
    |> normalize_text()
  end

  defp bulk_job_selector_limit(job) do
    job
    |> Map.get(:payload, %{})
    |> Map.get(@payload_selector_limit_key, "-")
  end

  defp bulk_dashboard_stats(jobs) do
    jobs = List.wrap(jobs)
    completed = Enum.filter(jobs, &(&1.status == :completed))
    active_count = Enum.count(jobs, &(&1.status in [:queued, :sent, :acknowledged, :running]))
    throttled_count = Enum.count(jobs, &bulk_throttled?/1)

    avg_rate =
      completed
      |> Enum.map(&bulk_rate_value/1)
      |> Enum.reject(&(&1 <= 0))
      |> average_float()

    total_targets =
      completed
      |> Enum.map(&bulk_count(&1, @payload_total_targets_key, count_targets(&1)))
      |> Enum.filter(&is_integer/1)
      |> Enum.sum()

    avg_success_rate =
      completed
      |> Enum.map(&bulk_success_rate/1)
      |> average_float()

    timed_out_targets =
      completed
      |> Enum.map(&bulk_timeout_count/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.sum()

    %{
      active_count: active_count,
      throttled_count: throttled_count,
      avg_rate: Float.round(avg_rate, 1),
      avg_success_rate: Float.round(avg_success_rate, 1),
      timed_out_targets: timed_out_targets,
      total_targets: total_targets
    }
  end

  defp recent_bulk_job_bars(jobs) do
    jobs = List.wrap(jobs)

    completed_jobs = Enum.filter(jobs, &(&1.status == :completed and bulk_rate_value(&1) > 0))

    if completed_jobs == [] do
      Enum.take(jobs, 8)
    else
      Enum.take(completed_jobs, 8)
    end
  end

  defp bulk_bar_width(job, max_rate) do
    rate = bulk_rate_value(job)
    ratio = safe_ratio(rate, max_rate)
    "#{Float.round(ratio * 100, 1)}%"
  end

  defp bulk_history_bar_width(sample) do
    max_concurrency = Map.get(sample, :max_concurrency, 0)
    concurrency = Map.get(sample, :concurrency, 0)
    ratio = safe_ratio(concurrency, max_concurrency)
    "#{Float.round(ratio * 100, 1)}%"
  end

  defp latest_bulk_history(jobs) do
    jobs
    |> List.wrap()
    |> Enum.find_value(fn job ->
      history = bulk_concurrency_history(job)
      if history == [], do: nil, else: %{job: job, history: history}
    end)
  end

  defp latest_bulk_mix(jobs) do
    jobs
    |> List.wrap()
    |> Enum.find_value(fn job ->
      mix = bulk_mix(job)
      if mix.total_targets > 0, do: %{job: job, mix: mix}
    end)
  end

  defp average_float([]), do: 0.0
  defp average_float(values), do: Enum.sum(values) / length(values)

  defp safe_ratio(_value, max_value) when max_value in [0, 0.0], do: 0.0
  defp safe_ratio(value, max_value), do: min(1.0, max(value / max_value, 0.0))

  defp execution_profile_fast, do: @execution_profile_fast
  defp execution_profile_balanced, do: @execution_profile_balanced
  defp execution_profile_deep, do: @execution_profile_deep
  defp payload_agent_id_key, do: @payload_agent_id_key
  defp payload_completed_targets_key, do: @payload_completed_targets_key
  defp payload_concurrency_key, do: @payload_concurrency_key
  defp payload_execution_profile_key, do: @payload_execution_profile_key
  defp payload_failed_targets_key, do: @payload_failed_targets_key
  defp payload_protocol_key, do: @payload_protocol_key
  defp payload_running_targets_key, do: @payload_running_targets_key
  defp payload_check_name_key, do: @payload_check_name_key
  defp payload_ip_version_key, do: @payload_ip_version_key
  defp payload_selector_limit_key, do: @payload_selector_limit_key
  defp payload_target_ip_key, do: @payload_target_ip_key
  defp payload_target_key, do: @payload_target_key
  defp payload_target_query_key, do: @payload_target_query_key
  defp payload_total_targets_key, do: @payload_total_targets_key
  defp protocol_icmp, do: @protocol_icmp
  defp protocol_tcp, do: @protocol_tcp
  defp protocol_udp, do: @protocol_udp

  defp wrap_manual_bulk_targets([]), do: {:error, :missing_targets}
  defp wrap_manual_bulk_targets(targets), do: {:ok, targets}

  defp wrap_srql_bulk_targets({:ok, []}), do: {:error, :empty_srql_targets}
  defp wrap_srql_bulk_targets({:error, reason}), do: {:error, {:srql_query_failed, reason}}

  defp wrap_srql_bulk_targets({:ok, target_contexts}) do
    target_contexts
    |> Enum.map(&bulk_target_from_ctx/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> wrap_srql_resolved_targets()
  end

  defp wrap_srql_resolved_targets([]), do: {:error, :empty_srql_targets}
  defp wrap_srql_resolved_targets(targets), do: {:ok, targets}

  defp mix_segment_width(count, total) do
    "#{Float.round(safe_ratio(count, total) * 100, 1)}%"
  end

  defp extract_float_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_float_metric(_payload, _key), do: nil

  defp extract_int_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp refresh_diagnostics(socket) do
    socket
    |> load_traces()
    |> load_pending_jobs()
    |> load_bulk_jobs()
  end

  defp schedule_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      nil ->
        ref = Process.send_after(self(), :refresh_diagnostics, 250)
        assign(socket, :refresh_timer, ref)

      _ref ->
        socket
    end
  end

  defp load_traces(socket) do
    srql_query = Map.get(socket.assigns.srql || %{}, :query, "")

    case MtrData.list_traces_paginated(
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent,
           srql_query: srql_query,
           limit: socket.assigns.limit,
           page: socket.assigns.current_page
         ) do
      {:ok, %{rows: traces, total_count: total_count, page: page, per_page: limit}} ->
        socket
        |> assign(:traces, traces)
        |> assign(:total_count, total_count)
        |> assign(:current_page, page)
        |> assign(:limit, limit)

      {:error, _} ->
        socket
        |> assign(:traces, [])
        |> assign(:total_count, 0)
    end
  end

  defp load_pending_jobs(socket) do
    case MtrData.list_pending_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} ->
        assign(
          socket,
          :pending_jobs,
          MtrData.suppress_completed_pending_jobs(jobs, socket.assigns.traces)
        )

      {:error, _} ->
        assign(socket, :pending_jobs, [])
    end
  end

  defp load_bulk_jobs(socket) do
    case MtrData.list_bulk_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} -> assign(socket, :bulk_jobs, jobs)
      {:error, _} -> assign(socket, :bulk_jobs, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <% dashboard = bulk_dashboard_stats(@bulk_jobs) %>
      <% recent_bars = recent_bulk_job_bars(@bulk_jobs) %>
      <% max_rate = recent_bars |> Enum.map(&bulk_rate_value/1) |> Enum.max(fn -> 0.0 end) %>
      <% latest_history = latest_bulk_history(@bulk_jobs) %>
      <% latest_mix = latest_bulk_mix(@bulk_jobs) %>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">MTR Diagnostics</h1>
            <p class="text-sm text-base-content/60 mt-1">Network path analysis traces from agents</p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/diagnostics/mtr/compare"} class="btn btn-sm btn-outline">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3"
                />
              </svg>
              Compare
            </.link>
            <button type="button" phx-click="open_mtr_modal" class="btn btn-sm btn-primary">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              Run MTR
            </button>
            <button type="button" phx-click="open_bulk_mtr_modal" class="btn btn-sm btn-secondary">
              Bulk MTR
            </button>
          </div>
        </div>

        <div :if={@bulk_jobs != []} class="overflow-x-auto">
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4 mb-4">
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Active Bulk Jobs</div>
              <div class="mt-2 text-3xl font-semibold">{dashboard.active_count}</div>
            </div>
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Avg Throughput</div>
              <div class="mt-2 text-3xl font-semibold">{dashboard.avg_rate}</div>
              <div class="text-sm text-base-content/60">targets/min</div>
            </div>
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Avg Success Rate</div>
              <div class="mt-2 text-3xl font-semibold">{dashboard.avg_success_rate}%</div>
            </div>
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                Recent Timed Out Targets
              </div>
              <div class="mt-2 text-3xl font-semibold">{dashboard.timed_out_targets}</div>
            </div>
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                Adaptive Backoff Runs
              </div>
              <div class="mt-2 text-3xl font-semibold">{dashboard.throttled_count}</div>
            </div>
          </div>

          <div class="grid grid-cols-1 xl:grid-cols-2 gap-4 mb-4">
            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="flex items-center justify-between">
                <h3 class="font-semibold">Recent Throughput</h3>
                <div class="text-xs text-base-content/60">last {length(recent_bars)} jobs</div>
              </div>
              <div class="mt-4 space-y-3">
                <div :for={job <- recent_bars} class="space-y-1">
                  <div class="flex items-center justify-between text-xs">
                    <span class="truncate max-w-[220px]">{job.agent_id}</span>
                    <span>{bulk_rate(job)}</span>
                  </div>
                  <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                    <div
                      class={[
                        "h-full rounded-full transition-all",
                        if(bulk_throttled?(job), do: "bg-warning", else: "bg-primary")
                      ]}
                      style={"width: #{bulk_bar_width(job, max_rate)}"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div class="rounded-xl border border-base-300 bg-base-100/80 p-4">
              <div class="flex items-center justify-between">
                <h3 class="font-semibold">Adaptive Concurrency</h3>
                <div class="text-xs text-base-content/60">
                  <%= if latest_history do %>
                    {latest_history.job.agent_id}
                  <% else %>
                    no history yet
                  <% end %>
                </div>
              </div>
              <div :if={latest_history} class="mt-4 space-y-3">
                <div :for={sample <- latest_history.history} class="space-y-1">
                  <div class="flex items-center justify-between text-xs">
                    <span>{sample.elapsed_ms}ms</span>
                    <span>{sample.concurrency}/{sample.max_concurrency}</span>
                  </div>
                  <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                    <div
                      class={[
                        "h-full rounded-full transition-all",
                        if(sample.concurrency < sample.max_concurrency,
                          do: "bg-warning",
                          else: "bg-success"
                        )
                      ]}
                      style={"width: #{bulk_history_bar_width(sample)}"}
                    >
                    </div>
                  </div>
                </div>
              </div>
              <div :if={!latest_history} class="mt-4 text-sm text-base-content/60">
                Run a bulk job long enough to trigger calibration windows and adaptive snapshots.
              </div>
            </div>
          </div>

          <div
            :if={latest_mix}
            class="rounded-xl border border-base-300 bg-base-100/80 p-4 mb-4"
          >
            <div class="flex items-center justify-between">
              <h3 class="font-semibold">Latest Run Mix</h3>
              <div class="text-xs text-base-content/60">
                {latest_mix.job.agent_id} • {bulk_success_rate(latest_mix.job)}% success
              </div>
            </div>
            <div class="mt-4 h-3 rounded-full bg-base-200 overflow-hidden flex">
              <div
                class="h-full bg-success"
                style={"width: #{mix_segment_width(latest_mix.mix.completed_targets, latest_mix.mix.total_targets)}"}
              >
              </div>
              <div
                class="h-full bg-warning"
                style={"width: #{mix_segment_width(latest_mix.mix.timed_out_targets, latest_mix.mix.total_targets)}"}
              >
              </div>
              <div
                class="h-full bg-error"
                style={"width: #{mix_segment_width(latest_mix.mix.error_targets, latest_mix.mix.total_targets)}"}
              >
              </div>
            </div>
            <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3 text-xs">
              <div class="rounded-lg bg-base-200/70 p-3">
                <div class="text-base-content/60 uppercase tracking-wide">Completed</div>
                <div class="mt-1 text-lg font-semibold">{latest_mix.mix.completed_targets}</div>
              </div>
              <div class="rounded-lg bg-base-200/70 p-3">
                <div class="text-base-content/60 uppercase tracking-wide">Timed Out</div>
                <div class="mt-1 text-lg font-semibold">{latest_mix.mix.timed_out_targets}</div>
              </div>
              <div class="rounded-lg bg-base-200/70 p-3">
                <div class="text-base-content/60 uppercase tracking-wide">Other Failures</div>
                <div class="mt-1 text-lg font-semibold">{latest_mix.mix.error_targets}</div>
              </div>
            </div>
          </div>

          <table class="table table-sm table-zebra">
            <thead>
              <tr>
                <th>Submitted</th>
                <th>Status</th>
                <th>Agent</th>
                <th>Targets</th>
                <th>Progress</th>
                <th>Rate</th>
                <th>Concurrency</th>
                <th>Profile</th>
                <th>Source</th>
                <th>Protocol</th>
                <th>Job</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @bulk_jobs} class="hover">
                <td class="whitespace-nowrap text-xs">{format_time(job.inserted_at)}</td>
                <td>
                  <span class={["badge badge-sm", pending_status_class(job.status)]}>
                    {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
                  </span>
                </td>
                <td class="text-xs font-mono max-w-[120px] truncate" title={job.agent_id}>
                  {job.agent_id}
                </td>
                <td>{bulk_count(job, payload_total_targets_key(), count_targets(job))}</td>
                <td class="text-xs">
                  {bulk_count(job, payload_completed_targets_key(), 0)}/{bulk_count(
                    job,
                    payload_total_targets_key(),
                    count_targets(job)
                  )} complete, {bulk_count(job, payload_failed_targets_key(), 0)} failed, {bulk_count(
                    job,
                    payload_running_targets_key(),
                    0
                  )} running
                  <div :if={bulk_timeout_count(job) > 0} class="text-warning">
                    {bulk_timeout_count(job)} timed out
                  </div>
                </td>
                <td class="text-xs">
                  <div>{bulk_rate(job)}</div>
                  <div class="text-base-content/60">{bulk_duration(job)}</div>
                </td>
                <td class="text-xs">
                  <div>{bulk_concurrency(job)}</div>
                  <div :if={bulk_throttled?(job)} class="text-warning">
                    adaptive backoff
                  </div>
                </td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {String.upcase(
                      (job.payload || %{})[payload_execution_profile_key()] ||
                        execution_profile_fast()
                    )}
                  </span>
                </td>
                <td class="text-xs">
                  <%= if bulk_job_query(job) != "" do %>
                    <div class="badge badge-info badge-sm">SRQL</div>
                    <div
                      class="text-base-content/60 mt-1 truncate max-w-[220px]"
                      title={bulk_job_query(job)}
                    >
                      {bulk_job_query(job)}
                    </div>
                    <div class="text-base-content/50">
                      limit {bulk_job_selector_limit(job)}
                    </div>
                  <% else %>
                    <span class="badge badge-ghost badge-sm">MANUAL</span>
                  <% end %>
                </td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {String.upcase((job.payload || %{})[payload_protocol_key()] || protocol_icmp())}
                  </span>
                </td>
                <td class="text-xs text-base-content/50">{job.id}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <form phx-change="filter" class="flex gap-3">
          <input
            type="text"
            name="target"
            value={@filter_target}
            placeholder="Filter by target..."
            class="input input-sm input-bordered w-48"
            phx-debounce="300"
          />
          <input
            type="text"
            name="agent"
            value={@filter_agent}
            placeholder="Filter by agent..."
            class="input input-sm input-bordered w-48"
            phx-debounce="300"
          />
        </form>

        <div class="overflow-x-auto">
          <table class="table table-sm table-zebra">
            <thead>
              <tr>
                <th>Time</th>
                <th>Target</th>
                <th>Status</th>
                <th>Hops</th>
                <th>Protocol</th>
                <th>Agent</th>
                <th>Check</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @pending_jobs} class="hover opacity-80">
                <td class="whitespace-nowrap text-xs">
                  {format_time(job.inserted_at)}
                </td>
                <td>
                  <div class="font-mono text-sm">{job.payload[payload_target_key()] || "-"}</div>
                </td>
                <td>
                  <span class={[
                    "badge badge-sm w-28 justify-center",
                    pending_status_class(job.status)
                  ]}>
                    {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
                  </span>
                </td>
                <td class="text-center">-</td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {String.upcase((job.payload || %{})[payload_protocol_key()] || protocol_icmp())}
                  </span>
                </td>
                <td class="text-xs font-mono max-w-[120px] truncate" title={job.agent_id}>
                  {job.agent_id}
                </td>
                <td class="text-xs max-w-[120px] truncate" title={job.command_type}>
                  pending
                </td>
                <td class="text-xs text-base-content/50">
                  {job.id}
                </td>
              </tr>
              <tr :for={trace <- @traces} class="hover">
                <td class="whitespace-nowrap text-xs">
                  {format_time(trace["time"])}
                </td>
                <td>
                  <div class="font-mono text-sm">{trace[payload_target_key()]}</div>
                  <div
                    :if={trace[payload_target_ip_key()] != trace[payload_target_key()]}
                    class="text-xs text-base-content/50"
                  >
                    {trace[payload_target_ip_key()]}
                  </div>
                </td>
                <td>
                  <span class={["badge badge-sm w-32 justify-center", trace_status_class(trace)]}>
                    {trace_status_label(trace)}
                  </span>
                </td>
                <td class="text-center">{trace["total_hops"]}</td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {String.upcase(trace[payload_protocol_key()] || protocol_icmp())}
                  </span>
                  <span
                    :if={trace[payload_ip_version_key()] == 6}
                    class="badge badge-info badge-sm ml-1"
                  >
                    IPv6
                  </span>
                </td>
                <td
                  class="text-xs font-mono max-w-[120px] truncate"
                  title={trace[payload_agent_id_key()]}
                >
                  {trace[payload_agent_id_key()]}
                </td>
                <td class="text-xs max-w-[120px] truncate" title={trace[payload_check_name_key()]}>
                  {trace[payload_check_name_key()] || "-"}
                </td>
                <td class="flex items-center gap-1">
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="run_again"
                    phx-value-target={trace[payload_target_key()] || ""}
                    phx-value-agent_id={trace[payload_agent_id_key()] || ""}
                    phx-value-protocol={trace[payload_protocol_key()] || protocol_icmp()}
                    title="Run again"
                    aria-label="Run MTR trace again"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-3.5 w-3.5"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M4 4v6h6M20 20v-6h-6M20 9A8 8 0 006.34 5.34L4 8m16 8l-2.34 2.66A8 8 0 013.99 15"
                      />
                    </svg>
                  </button>
                  <.link
                    navigate={~p"/diagnostics/mtr/#{trace["id"]}"}
                    class="btn btn-xs btn-ghost"
                  >
                    View
                  </.link>
                </td>
              </tr>
              <tr :if={@pending_jobs == [] and @traces == []}>
                <td colspan="8" class="text-center py-8 text-base-content/50">
                  No MTR traces found. Traces will appear once agents run MTR checks.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="pt-1">
          <.mtr_pagination
            page={@current_page}
            limit={@limit}
            total_count={@total_count}
            query={Map.get(@srql || %{}, :query, "")}
            filter_target={@filter_target}
            filter_agent={@filter_agent}
          />
        </div>

        <%= if @show_mtr_modal do %>
          <div class="modal modal-open">
            <div class="modal-box">
              <h3 class="font-bold text-lg mb-4">Run MTR Trace</h3>

              <div :if={@mtr_error} class="alert alert-error mb-4">
                <span>{@mtr_error}</span>
              </div>

              <.form for={@mtr_form} phx-submit="run_mtr">
                <div class="form-control mb-3">
                  <label class="label">
                    <span class="label-text">Target (hostname or IP)</span>
                  </label>
                  <input
                    type="text"
                    name="mtr[target]"
                    value={@mtr_form[payload_target_key()].value}
                    placeholder="e.g. 8.8.8.8 or google.com"
                    class="input input-bordered"
                    required
                  />
                </div>

                <div class="form-control mb-3">
                  <label class="label">
                    <span class="label-text">Agent</span>
                  </label>
                  <select
                    name="mtr[agent_id]"
                    class="select select-bordered"
                    required
                  >
                    <option value="">Select an agent...</option>
                    <%= for agent <- @mtr_agents do %>
                      <option value={agent_id(agent)}>{agent_label(agent)}</option>
                    <% end %>
                  </select>
                  <label :if={@mtr_agents == []} class="label">
                    <span class="label-text-alt text-warning">No agents connected</span>
                  </label>
                </div>

                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text">Protocol</span>
                  </label>
                  <select name="mtr[protocol]" class="select select-bordered">
                    <option value={protocol_icmp()} selected>ICMP</option>
                    <option value={protocol_udp()}>UDP</option>
                    <option value={protocol_tcp()}>TCP</option>
                  </select>
                </div>

                <div class="modal-action">
                  <button type="button" phx-click="close_mtr_modal" class="btn">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary">
                    Queue Trace
                  </button>
                </div>
              </.form>
            </div>
            <div class="modal-backdrop" phx-click="close_mtr_modal"></div>
          </div>
        <% end %>

        <%= if @show_bulk_mtr_modal do %>
          <div class="modal modal-open">
            <div class="modal-box max-w-2xl">
              <h3 class="font-bold text-lg mb-4">Run Bulk MTR</h3>

              <div :if={@bulk_mtr_error} class="alert alert-error mb-4">
                <span>{@bulk_mtr_error}</span>
              </div>

              <.form for={@bulk_mtr_form} phx-submit="run_bulk_mtr">
                <div class="form-control mb-3">
                  <label class="label">
                    <span class="label-text">SRQL Query</span>
                  </label>
                  <input
                    type="text"
                    name="bulk_mtr[target_query]"
                    value={@bulk_mtr_form[payload_target_query_key()].value}
                    placeholder="in:devices tags.role:edge"
                    class="input input-bordered"
                  />
                  <label class="label">
                    <span class="label-text-alt">
                      Optional. When present, ServiceRadar reruns the SRQL query at submit time and queues the current matching targets.
                    </span>
                  </label>
                </div>

                <div class="form-control mb-3">
                  <label class="label">
                    <span class="label-text">Targets</span>
                  </label>
                  <textarea
                    name="bulk_mtr[targets]"
                    class="textarea textarea-bordered min-h-48"
                    placeholder="One hostname or IP per line"
                  ><%= @bulk_mtr_form["targets"].value %></textarea>
                  <label class="label">
                    <span class="label-text-alt">
                      Optional when using SRQL. Manual targets are used only when the SRQL query field is blank.
                    </span>
                  </label>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                  <div class="form-control">
                    <label class="label"><span class="label-text">Selector Limit</span></label>
                    <input
                      type="number"
                      min="1"
                      max="5000"
                      name="bulk_mtr[selector_limit]"
                      value={@bulk_mtr_form[payload_selector_limit_key()].value}
                      class="input input-bordered"
                    />
                  </div>

                  <div class="form-control">
                    <label class="label"><span class="label-text">Agent</span></label>
                    <select name="bulk_mtr[agent_id]" class="select select-bordered" required>
                      <option value="">Select an agent...</option>
                      <%= for agent <- @mtr_agents do %>
                        <option value={agent_id(agent)}>{agent_label(agent)}</option>
                      <% end %>
                    </select>
                  </div>

                  <div class="form-control">
                    <label class="label"><span class="label-text">Protocol</span></label>
                    <select name="bulk_mtr[protocol]" class="select select-bordered">
                      <option
                        value={protocol_icmp()}
                        selected={@bulk_mtr_form[payload_protocol_key()].value == protocol_icmp()}
                      >
                        ICMP
                      </option>
                      <option
                        value={protocol_udp()}
                        selected={@bulk_mtr_form[payload_protocol_key()].value == protocol_udp()}
                      >
                        UDP
                      </option>
                      <option
                        value={protocol_tcp()}
                        selected={@bulk_mtr_form[payload_protocol_key()].value == protocol_tcp()}
                      >
                        TCP
                      </option>
                    </select>
                  </div>

                  <div class="form-control">
                    <label class="label"><span class="label-text">Execution Profile</span></label>
                    <select name="bulk_mtr[execution_profile]" class="select select-bordered">
                      <option
                        value={execution_profile_fast()}
                        selected={
                          @bulk_mtr_form[payload_execution_profile_key()].value ==
                            execution_profile_fast()
                        }
                      >
                        Fast
                      </option>
                      <option
                        value={execution_profile_balanced()}
                        selected={
                          @bulk_mtr_form[payload_execution_profile_key()].value ==
                            execution_profile_balanced()
                        }
                      >
                        Balanced
                      </option>
                      <option
                        value={execution_profile_deep()}
                        selected={
                          @bulk_mtr_form[payload_execution_profile_key()].value ==
                            execution_profile_deep()
                        }
                      >
                        Deep
                      </option>
                    </select>
                  </div>

                  <div class="form-control">
                    <label class="label"><span class="label-text">Concurrency</span></label>
                    <input
                      type="number"
                      min="1"
                      max="256"
                      name="bulk_mtr[concurrency]"
                      value={@bulk_mtr_form[payload_concurrency_key()].value}
                      class="input input-bordered"
                    />
                  </div>
                </div>

                <div class="modal-action">
                  <button type="button" phx-click="close_bulk_mtr_modal" class="btn">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-secondary">
                    Queue Bulk Job
                  </button>
                </div>
              </.form>
            </div>
            <div class="modal-backdrop" phx-click="close_bulk_mtr_modal"></div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr(:page, :integer, required: true)
  attr(:limit, :integer, required: true)
  attr(:total_count, :integer, required: true)
  attr(:query, :string, default: "")
  attr(:filter_target, :string, default: "")
  attr(:filter_agent, :string, default: "")

  defp mtr_pagination(assigns) do
    total_pages = max(1, ceil(assigns.total_count / max(assigns.limit, 1)))
    has_prev = assigns.page > 1
    has_next = assigns.page < total_pages

    prev_params =
      pagination_params(
        assigns.query,
        max(assigns.page - 1, 1),
        assigns.limit,
        assigns.filter_target,
        assigns.filter_agent
      )

    next_params =
      pagination_params(
        assigns.query,
        min(assigns.page + 1, total_pages),
        assigns.limit,
        assigns.filter_target,
        assigns.filter_agent
      )

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)
      |> assign(:prev_path, patch_path(prev_params))
      |> assign(:next_path, patch_path(next_params))

    ~H"""
    <div class="flex items-center justify-between gap-3 border-t border-base-200 pt-4">
      <div class="text-sm text-base-content/60">
        {if @total_count > 0,
          do: "Showing page #{@page} of #{@total_pages} (#{@total_count} total)",
          else: "No results"}
      </div>
      <div class="join">
        <.link :if={@has_prev} patch={@prev_path} class="join-item btn btn-sm btn-outline">
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.link>
        <button :if={!@has_prev} class="join-item btn btn-sm btn-outline" disabled>
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </button>
        <span class="join-item btn btn-sm btn-ghost pointer-events-none">
          {@page} / {@total_pages}
        </span>
        <.link :if={@has_next} patch={@next_path} class="join-item btn btn-sm btn-outline">
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.link>
        <button :if={!@has_next} class="join-item btn btn-sm btn-outline" disabled>
          Next <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp agent_id(agent) do
    Map.get(agent, :agent_id) || Map.get(agent, "agent_id") || ""
  end

  defp agent_label(agent) do
    id = agent_id(agent)
    partition = Map.get(agent, :partition_id) || Map.get(agent, "partition_id")

    if partition && partition != "" && partition != "default" do
      "#{id} (#{partition})"
    else
      id
    end
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(_), do: "-"

  defp pending_status_class(:queued), do: "badge-ghost"
  defp pending_status_class(:sent), do: "badge-info"
  defp pending_status_class(:acknowledged), do: "badge-info"
  defp pending_status_class(:running), do: "badge-warning"
  defp pending_status_class(_), do: "badge-ghost"

  defp trace_status_label(trace) when is_map(trace) do
    reached? = trace["target_reached"] == true
    protocol = trace[@payload_protocol_key] |> to_string() |> String.downcase()
    total_hops = trace["total_hops"] || 0

    cond do
      reached? ->
        "Reached"

      protocol == "tcp" and is_integer(total_hops) and total_hops > 0 ->
        "No Terminal Reply"

      true ->
        "Unreachable"
    end
  end

  defp trace_status_label(_), do: "Unreachable"

  defp trace_status_class(trace) when is_map(trace) do
    case trace_status_label(trace) do
      "Reached" -> "badge-success"
      "No Terminal Reply" -> "badge-warning"
      _ -> "badge-error"
    end
  end

  defp trace_status_class(_), do: "badge-error"

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp parse_limit(nil, default), do: default

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default)
      _ -> default
    end
  end

  defp parse_limit(limit, _default) when is_integer(limit) do
    limit |> max(1) |> min(@max_limit)
  end

  defp parse_limit(_limit, default), do: default

  defp sync_srql_state(socket, params, uri) do
    query = normalize_text(Map.get(params, "q"))

    srql =
      (socket.assigns[:srql] || %{})
      |> Map.put(:enabled, true)
      |> Map.put(:entity, "mtr_traces")
      |> Map.put(:page_path, uri_path(uri, "/diagnostics/mtr"))
      |> Map.put(:query, default_query(query, socket.assigns.limit))
      |> Map.put(:draft, default_query(query, socket.assigns.limit))

    assign(socket, :srql, srql)
  end

  defp uri_path(uri, fallback) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> fallback
    end
  end

  defp uri_path(_uri, fallback), do: fallback

  defp default_query("", limit), do: "in:mtr_traces sort:time:desc limit:#{limit}"
  defp default_query(query, _limit), do: query

  defp patch_path(params) do
    cleaned =
      Map.reject(params, fn {_k, v} -> is_nil(v) or v == "" end)

    "/diagnostics/mtr?" <> URI.encode_query(cleaned)
  end

  defp pagination_params(query, page, limit, target, agent) do
    %{
      "q" => query,
      "page" => page,
      "limit" => limit,
      "target" => target,
      "agent" => agent
    }
  end

  defp extra_query_params(socket) do
    %{
      "target" => socket.assigns.filter_target,
      "agent" => socket.assigns.filter_agent,
      "page" => 1
    }
  end

  defp maybe_put_query(params, ""), do: Map.delete(params, "q")
  defp maybe_put_query(params, query), do: Map.put(params, "q", query)

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> to_string() |> String.trim()
end
