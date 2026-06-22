defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Filters do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows, only: [has_any_filter?: 1, has_filter?: 3]

  def render(assigns) do
    ~H"""
    <!-- Quick Filters -->
    <div class="mb-4 flex flex-wrap items-center gap-2">
      <span class="text-xs font-medium text-base-content/60 mr-1">Quick filters:</span>
      <.link
        navigate={~p"/devices?q=in:devices is_available:true"}
        class={"btn btn-xs #{if has_filter?(@srql, "is_available", "true"), do: "btn-primary", else: "btn-ghost"}"}
      >
        <.icon name="hero-check-circle" class="size-3" /> Available
      </.link>
      <.link
        navigate={~p"/devices?q=in:devices is_available:false"}
        class={"btn btn-xs #{if has_filter?(@srql, "is_available", "false"), do: "btn-error", else: "btn-ghost"}"}
      >
        <.icon name="hero-x-circle" class="size-3" /> Unavailable
      </.link>
      <.link
        navigate={~p"/devices?q=in:devices is_active:true"}
        class={"btn btn-xs #{if has_filter?(@srql, "is_active", "true"), do: "btn-primary", else: "btn-ghost"}"}
      >
        <.icon name="hero-play-circle" class="size-3" /> In service
      </.link>
      <.link
        navigate={~p"/devices?q=in:devices is_active:false"}
        class={"btn btn-xs #{if has_filter?(@srql, "is_active", "false"), do: "btn-warning", else: "btn-ghost"}"}
      >
        <.icon name="hero-pause-circle" class="size-3" /> Out of service
      </.link>
      <.link
        navigate={~p"/devices?q=in:devices discovery_sources:(sweep)"}
        class={"btn btn-xs #{if has_filter?(@srql, "discovery_sources", "sweep"), do: "btn-info", else: "btn-ghost"}"}
      >
        <.icon name="hero-signal" class="size-3" /> Swept
      </.link>
      <button
        phx-click="toggle_include_deleted"
        class={"btn btn-xs #{if has_filter?(@srql, "include_deleted", "true"), do: "btn-secondary", else: "btn-ghost"}"}
      >
        <.icon name="hero-archive-box" class="size-3" /> Include deleted
      </button>
      <.link
        :if={has_any_filter?(@srql)}
        navigate={~p"/devices"}
        class="btn btn-xs btn-ghost"
      >
        <.icon name="hero-x-mark" class="size-3" /> Clear
      </.link>
    </div>
    """
  end
end
