defmodule ServiceRadarWebNGWeb.EventLive.Index do
  @moduledoc """
  Legacy `/events` list route.

  The events list lives on Observability → Events. This LiveView only exists so
  old bookmarks and links redirect cleanly (preserving `q` / limit / cursor).
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Events")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav =
      params
      |> Map.take(["q"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    to = ServiceRadarWebNGWeb.ObservabilityPaths.path("events", nav)
    {:noreply, push_navigate(socket, to: to)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex min-h-[40vh] items-center justify-center p-8">
        <p class="text-sm text-sr-muted">Redirecting to Observability → Events…</p>
      </div>
    </Layouts.app>
    """
  end
end
