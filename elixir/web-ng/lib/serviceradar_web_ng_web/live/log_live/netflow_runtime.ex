defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntime do
  @moduledoc """
  Per-view NetFlow loading gates for Observability.

  Inactive tabs must not issue SRQL, and a panel loads only on the views that
  render it. Errors from an active loader stay errors; they are not coerced
  into empty success.
  """

  # Must match the `:if={@view ...}` conditions in LogLive.Index. The talkers
  # icicle is drawn from the Sankey edges, so `:sankey` covers both views.
  @panel_views %{
    summary: ["overview", "all"],
    timeseries: ["overview", "traffic", "all"],
    stacked_timeseries: ["overview", "traffic", "all"],
    timeseries_compare: ["overview", "traffic", "all"],
    protocol_activity: ["traffic", "all"],
    app_activity: ["traffic", "all"],
    top_talkers: ["talkers", "all"],
    top_ports: ["talkers", "all"],
    frequent_talkers_packets: ["talkers", "all"],
    frequent_talkers_bytes: ["talkers", "all"],
    sankey: ["topology", "talkers", "all"],
    geo_heatmap: ["topology", "geo", "all"],
    threat_map: ["explorer", "all"],
    rdns_map: ["talkers", "explorer", "all"]
  }

  @type panel ::
          :summary
          | :timeseries
          | :stacked_timeseries
          | :timeseries_compare
          | :protocol_activity
          | :app_activity
          | :top_talkers
          | :top_ports
          | :frequent_talkers_packets
          | :frequent_talkers_bytes
          | :sankey
          | :geo_heatmap
          | :threat_map
          | :rdns_map

  @spec active_tab?(term()) :: boolean()
  def active_tab?("netflows"), do: true
  def active_tab?(_tab), do: false

  @spec should_load_panel?(term(), term(), panel()) :: boolean()
  def should_load_panel?(tab, view, panel), do: active_tab?(tab) and view in Map.fetch!(@panel_views, panel)

  @spec load_summary(term(), (-> result)) :: {:ok, term()} | {:error, term()} | {:skipped, :inactive_panel}
        when result: term() | {:ok, term()} | {:error, term()}
  def load_summary(tab, fun) when is_function(fun, 0) do
    if active_tab?(tab), do: invoke(fun), else: {:skipped, :inactive_panel}
  end

  @spec load_panel(term(), term(), panel(), (-> result)) ::
          {:ok, term()} | {:error, term()} | {:skipped, :inactive_panel}
        when result: term() | {:ok, term()} | {:error, term()}
  def load_panel(tab, view, panel, fun) when is_function(fun, 0) do
    if should_load_panel?(tab, view, panel), do: invoke(fun), else: {:skipped, :inactive_panel}
  end

  @typedoc "A loader, the key its result is filed under, and what to use if it never returns."
  @type job :: {term(), (-> term()), term()}

  @load_timeout_ms 30_000

  @max_panel_concurrency 4

  @doc """
  Returns the bounded concurrency cap for NetFlow panel loaders.
  """
  @spec max_panel_concurrency() :: pos_integer()
  def max_panel_concurrency do
    case Application.get_env(:serviceradar_web_ng, :netflow_panel_max_concurrency, @max_panel_concurrency) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> @max_panel_concurrency
    end
  end

  @doc """
  Runs independent panel loaders at the same time and returns their results by key.

  Each NetFlow panel is one or more warehouse round trips, and none of them
  needs another's answer, so up to four loaders can overlap. A loader that
  outlives the timeout is killed and its default is used, so one stuck query
  costs its own panel and not the page.

  Loaders that depend on another's result belong in a later call. The fixed
  concurrency cap bounds each viewer's warehouse fan-out.
  """
  @spec run_concurrently([job()], keyword()) :: %{optional(term()) => term()}
  def run_concurrently(jobs, opts \\ []) when is_list(jobs) do
    timeout = Keyword.get(opts, :timeout, @load_timeout_ms)
    concurrency_cap = Keyword.get(opts, :max_concurrency, max_panel_concurrency())

    jobs
    |> Task.async_stream(fn {_key, fun, _default} -> fun.() end,
      max_concurrency: min(max(length(jobs), 1), max(concurrency_cap, 1)),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(jobs)
    |> Map.new(fn
      {{:ok, value}, {key, _fun, _default}} -> {key, value}
      {{:exit, _reason}, {key, _fun, default}} -> {key, default}
    end)
  end

  defp invoke(fun) do
    case fun.() do
      {:error, reason} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      value -> {:ok, value}
    end
  end
end
