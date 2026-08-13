# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Load do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @spec empty(keyword()) :: map()
      def empty(opts \\ []) do
        time_window = Keyword.get(opts, :time_window, "last_24h")

        %{
          time_window: time_window,
          time_window_label: time_window_label(time_window),
          dashboard_modules: [:inventory, :health],
          module_states: %{
            inventory: :loading,
            health: :loading,
            netflow: :loading,
            mtr: :loading,
            camera: :loading,
            fieldsurvey: :loading,
            security_events: :loading,
            vulnerable_assets: :unconnected,
            siem: :unconnected
          },
          kpi_cards:
            kpi_cards(
              empty_device_summary(),
              empty_services_summary(),
              empty_flow_summary(),
              empty_camera_summary(),
              empty_survey_summary(),
              empty_alert_summary(),
              empty_event_summary(),
              empty_sparklines()
            ),
          map_stats: map_stats(empty_flow_summary(), empty_mtr_summary(), []),
          map_view: "netflow",
          traffic_links_window_label: netflow_map_window_label(),
          topology_links: [],
          topology_links_json: "[]",
          traffic_links: [],
          traffic_links_json: "[]",
          mtr_overlays: [],
          mtr_overlays_json: "[]",
          map_empty_title: "Checking traffic sources",
          map_empty_detail: "Dashboard data will load after the LiveView connects.",
          observability_metrics:
            observability_metrics(
              empty_flow_summary(),
              empty_mtr_summary(),
              empty_trace_summary(),
              empty_services_summary(),
              empty_sparklines()
            ),
          security_trend: [],
          security_trend_max: 0,
          security_summary: empty_event_summary(),
          threat_intel_summary: empty_threat_intel_summary(),
          alert_feed: [],
          camera_summary: empty_camera_summary(),
          survey_summary: empty_survey_summary(),
          virtualization_summary: empty_virtualization_summary()
        }
      end

      @spec load(term(), keyword()) :: map()
      def load(scope, opts \\ []) do
        time_window = Keyword.get(opts, :time_window, "last_24h")
        srql_module = Keyword.get(opts, :srql_module, default_srql_module())

        # Wave 1 — the independent queries run concurrently. Each underlying function
        # already rescues its own exceptions and returns its empty/default shape, so
        # a failing query degrades gracefully and never aborts the load (preserving
        # the pre-§39.1 failure semantics). mtr_summary / link_count / sparklines
        # are derived from these results in wave 2 below (their only true deps).
        # A {name, fun, default} triple is supplied so that even an unrescued raise
        # (e.g. the external ServiceRadarWebNG.TenantUsage/ServiceRadarWebNGWeb.Stats calls, which are NOT individually
        # rescued in load/2) degrades to its default instead of aborting the load.
        wave1 =
          run_concurrent(
            collector_counts: {fn -> ServiceRadarWebNG.TenantUsage.collector_counts_by_type() end, %{}},
            device_summary: {fn -> device_summary(scope) end, empty_device_summary()},
            services_summary: {fn -> services_summary(scope, time_window) end, empty_services_summary()},
            flow_summary: {fn -> flow_summary(time_window) end, empty_flow_summary()},
            traffic_links: {fn -> traffic_links(time_window) end, []},
            topology_links: {fn -> topology_links(time_window) end, []},
            mtr_overlays: {fn -> mtr_overlays() end, []},
            mtr_timeseries: {fn -> mtr_timeseries_summary(time_window) end, empty_mtr_summary()},
            camera_summary: {fn -> camera_summary(scope) end, empty_camera_summary()},
            alert_summary: {fn -> ServiceRadarWebNGWeb.Stats.alerts_summary(scope: scope) end, %{}},
            alert_feed: {fn -> alert_feed(time_window) end, []},
            event_summary: {fn -> ServiceRadarWebNGWeb.Stats.events_summary(time: time_window) end, %{}},
            threat_intel_summary: {fn -> threat_intel_summary() end, empty_threat_intel_summary()},
            trace_summary: {fn -> trace_summary(srql_module, scope, time_window) end, empty_trace_summary()},
            virtualization_summary:
              {fn -> virtualization_summary(srql_module, scope) end, empty_virtualization_summary()},
            security_trend: {fn -> security_trend(time_window) end, []}
          )

        %{
          collector_counts: collector_counts,
          device_summary: device_summary,
          services_summary: services_summary,
          flow_summary: flow_summary_raw,
          traffic_links: traffic_links,
          topology_links: topology_links,
          mtr_overlays: mtr_overlays,
          mtr_timeseries: mtr_timeseries,
          camera_summary: camera_summary,
          alert_summary: alert_summary,
          alert_feed: alert_feed,
          event_summary: event_summary,
          threat_intel_summary: threat_intel_summary,
          trace_summary: trace_summary,
          virtualization_summary: virtualization_summary,
          security_trend: security_trend
        } = wave1

        # Wave 2 — derived results that depend on wave 1 (pure post-processing).
        flow_summary =
          Map.put(
            flow_summary_raw,
            :link_count,
            max(length(traffic_links), length(topology_links))
          )

        mtr_summary = merge_mtr_summaries(mtr_timeseries, summarize_mtr_overlays(mtr_overlays))
        survey_summary = empty_survey_summary()
        sparklines = dashboard_sparklines(time_window, security_trend)

        module_states =
          module_states(
            collector_counts,
            flow_summary,
            traffic_links,
            mtr_summary,
            camera_summary,
            survey_summary,
            event_summary,
            alert_summary
          )

        %{
          time_window: time_window,
          time_window_label: time_window_label(time_window),
          dashboard_modules: enabled_modules(module_states),
          module_states: module_states,
          kpi_cards:
            kpi_cards(
              device_summary,
              services_summary,
              flow_summary,
              camera_summary,
              survey_summary,
              alert_summary,
              event_summary,
              sparklines
            ),
          map_stats: map_stats(flow_summary, mtr_summary, traffic_links),
          map_view: "netflow",
          traffic_links_window_label: netflow_map_window_label(),
          topology_links: topology_links,
          topology_links_json: Jason.encode!(topology_links),
          traffic_links: traffic_links,
          traffic_links_json: Jason.encode!(traffic_links),
          mtr_overlays: mtr_overlays,
          mtr_overlays_json: Jason.encode!(mtr_overlays),
          map_empty_title: map_empty_title(module_states.netflow),
          map_empty_detail: map_empty_detail(module_states.netflow),
          observability_metrics:
            observability_metrics(flow_summary, mtr_summary, trace_summary, services_summary, sparklines),
          security_trend: security_trend,
          security_trend_max: max_trend_total(security_trend),
          security_summary: event_summary,
          threat_intel_summary: threat_intel_summary,
          alert_feed: alert_feed,
          camera_summary: camera_summary,
          survey_summary: survey_summary,
          virtualization_summary: virtualization_summary
        }
      end

      # Runs a keyword list of {name, {fun, default}} pairs concurrently via
      # Task.async_stream and collects results into a map keyed by name. Tasks run
      # unordered. A task that raises, exits, or times out degrades to its supplied
      # default — so the load never aborts on a single failing/external query
      # (preserving and extending the per-query graceful-degradation semantics).
      defp run_concurrent(tasks) when is_list(tasks) do
        tasks
        |> Task.async_stream(
          fn {name, {fun, default}} ->
            try do
              {name, {:ok, fun.()}}
            catch
              _kind, _reason -> {name, {:error, default}}
            end
          end,
          ordered: false,
          timeout: 15_000,
          on_timeout: :kill_task
        )
        |> Enum.reduce(%{}, fn
          {:ok, {name, {:ok, value}}}, acc -> Map.put(acc, name, value)
          {:ok, {name, {:error, default}}}, acc -> Map.put(acc, name, default)
          {:exit, _reason}, acc -> acc
        end)
        |> fill_defaults(tasks)
      end

      # Any task that did not return at all (killed before reporting) keeps its
      # declared default so downstream destructuring never raises MatchError.
      defp fill_defaults(results, tasks) do
        Enum.reduce(tasks, results, fn {name, {_fun, default}}, acc ->
          Map.put_new(acc, name, default)
        end)
      end

      @spec load_netflow_map(term(), keyword()) :: map()
      def load_netflow_map(_scope, opts \\ []) do
        time_window = Keyword.get(opts, :time_window, "last_24h")

        wave1 =
          run_concurrent(
            collector_counts: {fn -> ServiceRadarWebNG.TenantUsage.collector_counts_by_type() end, %{}},
            flow_summary: {fn -> flow_summary(time_window) end, empty_flow_summary()},
            traffic_links: {fn -> traffic_links(time_window) end, []},
            topology_links: {fn -> topology_links(time_window) end, []},
            mtr_overlays: {fn -> mtr_overlays() end, []}
          )

        %{
          collector_counts: collector_counts,
          flow_summary: flow_summary_raw,
          traffic_links: traffic_links,
          topology_links: topology_links,
          mtr_overlays: mtr_overlays
        } = wave1

        flow_summary =
          Map.put(
            flow_summary_raw,
            :link_count,
            max(length(traffic_links), length(topology_links))
          )

        mtr_summary = summarize_mtr_overlays(mtr_overlays)
        netflow_state = netflow_source_state(collector_counts, flow_summary, traffic_links)

        %{
          time_window: time_window,
          time_window_label: time_window_label(time_window),
          netflow_state: netflow_state,
          map_stats: map_stats(flow_summary, mtr_summary, traffic_links),
          traffic_links_window_label: netflow_map_window_label(),
          topology_links: topology_links,
          topology_links_json: Jason.encode!(topology_links),
          traffic_links: traffic_links,
          traffic_links_json: Jason.encode!(traffic_links),
          mtr_overlays: mtr_overlays,
          mtr_overlays_json: Jason.encode!(mtr_overlays),
          map_empty_title: map_empty_title(netflow_state),
          map_empty_detail: map_empty_detail(netflow_state)
        }
      end

      @spec load_survey_summary(term()) :: map()
      def load_survey_summary(scope), do: survey_summary(scope)

      @spec survey_kpi_card(map(), list()) :: map()
      def survey_kpi_card(survey, sparkline \\ []) do
        %{
          title: "Wi-Fi Coverage",
          value: survey_value(survey),
          detail: survey_detail(survey),
          icon: "hero-wifi",
          tone: "violet",
          sparkline: sparkline,
          href: "/spatial/field-surveys",
          aria_label: "Open FieldSurvey Wi-Fi coverage"
        }
      end
    end
  end
end
