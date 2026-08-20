# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Load do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @spec empty(keyword()) :: map()
      def empty(opts \\ []) do
        time_window = Keyword.get(opts, :time_window, "last_24h")
        sources = empty_sources(time_window)

        sources
        |> Map.merge(%{
          map_view: "netflow",
          topology_links_json: "[]",
          traffic_links_json: "[]",
          mtr_overlays_json: "[]"
        })
        |> Map.merge(derive(sources))
      end

      defp empty_sources(time_window) do
        %{
          time_window: time_window,
          time_window_label: time_window_label(time_window),
          device_summary: empty_device_summary(),
          services_summary: empty_services_summary(),
          flow_summary: empty_flow_summary(),
          mtr_timeseries: empty_mtr_summary(),
          mtr_overlays: [],
          traffic_links: [],
          topology_links: [],
          collector_counts: %{},
          camera_summary: empty_camera_summary(),
          survey_summary: empty_survey_summary(),
          alert_summary: empty_alert_summary(),
          event_summary: empty_event_summary(),
          trace_summary: empty_trace_summary(),
          sparklines: empty_sparklines(),
          security_trend: [],
          threat_intel_summary: empty_threat_intel_summary(),
          alert_feed: [],
          vulnerable_assets: [],
          virtualization_summary: empty_virtualization_summary(),
          kpi_loading: default_kpi_loading(),
          loaded: %{}
        }
      end

      @spec derive(map()) :: map()
      def derive(sources) when is_map(sources) do
        device_summary = Map.get(sources, :device_summary, empty_device_summary())
        services_summary = Map.get(sources, :services_summary, empty_services_summary())
        flow_summary_raw = Map.get(sources, :flow_summary, empty_flow_summary())
        traffic_links = Map.get(sources, :traffic_links, [])
        topology_links = Map.get(sources, :topology_links, [])
        mtr_overlays = Map.get(sources, :mtr_overlays, [])
        mtr_timeseries = Map.get(sources, :mtr_timeseries, empty_mtr_summary())
        camera_summary = Map.get(sources, :camera_summary, empty_camera_summary())
        survey_summary = Map.get(sources, :survey_summary, empty_survey_summary())
        alert_summary = Map.get(sources, :alert_summary, empty_alert_summary())
        event_summary = Map.get(sources, :event_summary, empty_event_summary())
        trace_summary = Map.get(sources, :trace_summary, empty_trace_summary())
        sparklines = Map.get(sources, :sparklines, empty_sparklines())
        security_trend = Map.get(sources, :security_trend, [])
        collector_counts = Map.get(sources, :collector_counts, %{})
        loaded = Map.get(sources, :loaded, %{})
        kpi_loading = Map.get(sources, :kpi_loading, %{})

        flow_summary =
          Map.put(
            flow_summary_raw,
            :link_count,
            max(length(List.wrap(traffic_links)), length(List.wrap(topology_links)))
          )

        mtr_summary = merge_mtr_summaries(mtr_timeseries, summarize_mtr_overlays(mtr_overlays))

        module_states =
          collector_counts
          |> module_states(
            flow_summary,
            traffic_links,
            mtr_summary,
            camera_summary,
            survey_summary,
            event_summary,
            alert_summary
          )
          |> Map.put(
            :vulnerable_assets,
            if(Map.get(sources, :vulnerable_assets, []) == [], do: :configured_empty, else: :active)
          )
          |> overlay_loading_states(loaded)

        %{
          dashboard_modules: enabled_modules(module_states),
          module_states: module_states,
          kpi_cards:
            apply_kpi_loading(
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
              kpi_loading
            ),
          map_stats: map_stats(flow_summary, mtr_summary, traffic_links),
          traffic_links_window_label: netflow_map_window_label(),
          map_empty_title: map_empty_title(Map.get(module_states, :netflow)),
          map_empty_detail: map_empty_detail(Map.get(module_states, :netflow)),
          observability_metrics:
            observability_metrics(flow_summary, mtr_summary, trace_summary, services_summary, sparklines),
          security_trend_max: max_trend_total(security_trend),
          security_summary: event_summary,
          mtr_summary: mtr_summary,
          flow_summary: flow_summary
        }
      end

      defp overlay_loading_states(states, loaded) when is_map(states) and is_map(loaded) do
        Enum.reduce(
          [:inventory, :health, :netflow, :mtr, :camera, :fieldsurvey, :security_events, :vulnerable_assets, :siem],
          states,
          fn key, acc ->
            if Map.get(loaded, key, false) do
              acc
            else
              Map.put(acc, key, :loading)
            end
          end
        )
      end

      defp overlay_loading_states(states, _loaded), do: states

      defp all_loaded do
        %{
          inventory: true,
          health: true,
          netflow: true,
          mtr: true,
          camera: true,
          fieldsurvey: true,
          security_events: true,
          vulnerable_assets: true,
          siem: true
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
            security_trend: {fn -> security_trend(time_window) end, []},
            vulnerable_assets: {fn -> ServiceRadarWebNGWeb.DashboardLive.Data.VulnerableAssets.load() end, []}
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
          security_trend: security_trend,
          vulnerable_assets: vulnerable_assets
        } = wave1

        # Wave 2 — derived results that depend on wave 1 (pure post-processing).
        flow_summary =
          Map.put(
            flow_summary_raw,
            :link_count,
            max(length(traffic_links), length(topology_links))
          )

        survey_summary = empty_survey_summary()
        sparklines = dashboard_sparklines(time_window, security_trend)

        sources =
          time_window
          |> empty_sources()
          |> Map.merge(%{
            device_summary: device_summary,
            services_summary: services_summary,
            flow_summary: flow_summary,
            mtr_timeseries: mtr_timeseries,
            mtr_overlays: mtr_overlays,
            traffic_links: traffic_links,
            topology_links: topology_links,
            collector_counts: collector_counts,
            camera_summary: camera_summary,
            survey_summary: survey_summary,
            alert_summary: alert_summary,
            event_summary: event_summary,
            trace_summary: trace_summary,
            sparklines: sparklines,
            security_trend: security_trend,
            threat_intel_summary: threat_intel_summary,
            alert_feed: alert_feed,
            vulnerable_assets: vulnerable_assets,
            virtualization_summary: virtualization_summary,
            kpi_loading: loaded_kpi_loading(),
            loaded: all_loaded()
          })

        sources
        |> Map.merge(derive(sources))
        |> Map.merge(%{
          map_view: "netflow",
          topology_links_json: Jason.encode!(topology_links),
          traffic_links_json: Jason.encode!(traffic_links),
          mtr_overlays_json: Jason.encode!(mtr_overlays)
        })
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

      @spec load_inventory(term()) :: map()
      def load_inventory(scope) do
        %{device_summary: device_summary(scope)}
      rescue
        _ -> %{device_summary: empty_device_summary()}
      end

      @spec load_health(term(), String.t()) :: map()
      def load_health(scope, time_window) do
        %{services_summary: services_summary(scope, time_window)}
      rescue
        _ -> %{services_summary: empty_services_summary()}
      end

      @spec load_camera_summary(term()) :: map()
      def load_camera_summary(scope) do
        %{camera_summary: camera_summary(scope)}
      rescue
        _ -> %{camera_summary: empty_camera_summary()}
      end

      @spec load_alerts_summary(term()) :: map()
      def load_alerts_summary(scope) do
        %{alert_summary: ServiceRadarWebNGWeb.Stats.alerts_summary(scope: scope)}
      rescue
        _ -> %{alert_summary: empty_alert_summary()}
      end

      @spec load_events_summary(String.t()) :: map()
      def load_events_summary(time_window) do
        %{event_summary: ServiceRadarWebNGWeb.Stats.events_summary(time: time_window)}
      rescue
        _ -> %{event_summary: empty_event_summary()}
      end

      @spec load_mtr(String.t()) :: map()
      def load_mtr(time_window) do
        %{mtr_timeseries: mtr_timeseries_summary(time_window)}
      rescue
        _ -> %{mtr_timeseries: empty_mtr_summary()}
      end

      @spec load_traces(term(), String.t()) :: map()
      def load_traces(scope, time_window) do
        srql_module = default_srql_module()
        %{trace_summary: trace_summary(srql_module, scope, time_window)}
      rescue
        _ -> %{trace_summary: empty_trace_summary()}
      end

      @spec load_security_trend(String.t()) :: map()
      def load_security_trend(time_window) do
        %{security_trend: security_trend(time_window)}
      rescue
        _ -> %{security_trend: []}
      end

      @spec load_sparklines(String.t()) :: map()
      def load_sparklines(time_window) do
        %{sparklines: dashboard_sparklines(time_window, [])}
      rescue
        _ -> %{sparklines: empty_sparklines()}
      end

      @spec load_alert_feed(String.t()) :: map()
      def load_alert_feed(time_window) do
        %{alert_feed: alert_feed(time_window)}
      rescue
        _ -> %{alert_feed: []}
      end

      @spec load_threat_intel() :: map()
      def load_threat_intel do
        %{threat_intel_summary: threat_intel_summary()}
      rescue
        _ -> %{threat_intel_summary: empty_threat_intel_summary()}
      end

      @spec load_vulnerable_assets() :: map()
      def load_vulnerable_assets do
        %{vulnerable_assets: ServiceRadarWebNGWeb.DashboardLive.Data.VulnerableAssets.load()}
      rescue
        _ -> %{vulnerable_assets: []}
      end

      @spec load_virtualization(term()) :: map()
      def load_virtualization(scope) do
        %{virtualization_summary: virtualization_summary(default_srql_module(), scope)}
      rescue
        _ -> %{virtualization_summary: empty_virtualization_summary()}
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
          collector_counts: collector_counts,
          flow_summary: flow_summary,
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
