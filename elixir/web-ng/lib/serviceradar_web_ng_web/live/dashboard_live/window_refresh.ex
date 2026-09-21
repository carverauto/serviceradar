defmodule ServiceRadarWebNGWeb.DashboardLive.WindowRefresh do
  @moduledoc """
  What a dashboard panel shows while its time window is being reloaded.

  The previous window's data stays on screen until the new window arrives.
  Clearing it first made every window change look like a page refresh: the
  NetFlow map emptied to "no data", its tiles read zero, the Events chart was
  swapped for its empty state, and the KPI cards that summarise those sources
  flipped too -- Network Health to "No signal", Threat Level from the event
  count to the alert count -- for as long as the query took, which for a 90-day
  window is about two seconds. The panel is marked busy instead.

  A failed load is different: the select already names the new window, so
  leaving the old window's data under it would mislabel it. That is when the
  panel is cleared, alongside the error message.
  """

  alias ServiceRadarWebNGWeb.DashboardLive.Data

  @type kind :: String.t()
  @type sources :: map()
  @type loaded :: keyword(boolean())

  @doc "Source updates and loaded flags to apply when a reload starts: none."
  @spec on_start(kind()) :: {sources(), loaded()}
  def on_start(kind) when kind in ["netflow", "events"], do: {%{}, []}

  @doc "Source updates and loaded flags to apply when a reload fails."
  @spec on_failure(kind()) :: {sources(), loaded()}
  def on_failure("netflow") do
    {%{flow_summary: Data.empty().flow_summary, traffic_links: [], traffic_links_json: "[]"}, [netflow: true]}
  end

  def on_failure("events") do
    {%{security_trend: [], event_summary: Data.empty().event_summary}, [security_events: true]}
  end

  @doc "Whether a reload of `kind` is in flight, given the LiveView's `window_requests`."
  @spec busy?(map() | nil, kind()) :: boolean()
  def busy?(window_requests, kind) when is_map(window_requests), do: is_reference(window_requests[kind])
  def busy?(_window_requests, _kind), do: false
end
