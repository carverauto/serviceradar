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
    stacked_timeseries: ["overview", "traffic", "all"],
    sankey: ["topology", "talkers", "all"]
  }

  @type panel :: :stacked_timeseries | :sankey

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

  defp invoke(fun) do
    case fun.() do
      {:error, reason} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      value -> {:ok, value}
    end
  end
end
