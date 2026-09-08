defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Filters do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows, only: [has_any_filter?: 1, has_filter?: 3]

  alias ServiceRadarWebNGWeb.CompositeChecks.Catalog, as: CompositeCatalog

  def render(assigns) do
    ~H"""
    <!-- Quick Filters -->
    <div class="mb-4 flex flex-wrap items-center gap-2">
      <span class="mr-1 text-xs font-medium text-sr-muted">Quick filters:</span>
      <.ui_button
        navigate={~p"/devices?q=in:devices is_available:true"}
        size="xs"
        variant={if has_filter?(@srql, "is_available", "true"), do: "primary", else: "ghost"}
      >
        <.icon name="hero-check-circle" class="size-3" /> Available
      </.ui_button>
      <.ui_button
        navigate={~p"/devices?q=in:devices is_available:false"}
        size="xs"
        variant={if has_filter?(@srql, "is_available", "false"), do: "danger", else: "ghost"}
      >
        <.icon name="hero-x-circle" class="size-3" /> Unavailable
      </.ui_button>
      <.ui_button
        navigate={~p"/devices?q=in:devices is_active:true"}
        size="xs"
        variant={if has_filter?(@srql, "is_active", "true"), do: "primary", else: "ghost"}
      >
        <.icon name="hero-play-circle" class="size-3" /> In service
      </.ui_button>
      <.ui_button
        navigate={~p"/devices?q=in:devices is_active:false"}
        size="xs"
        variant={if has_filter?(@srql, "is_active", "false"), do: "warning", else: "ghost"}
      >
        <.icon name="hero-pause-circle" class="size-3" /> Out of service
      </.ui_button>
      <.ui_button
        navigate={~p"/devices?q=in:devices discovery_sources:(sweep)"}
        size="xs"
        variant={if has_filter?(@srql, "discovery_sources", "sweep"), do: "info", else: "ghost"}
      >
        <.icon name="hero-signal" class="size-3" /> Swept
      </.ui_button>
      <.ui_button
        type="button"
        phx-click="toggle_include_deleted"
        size="xs"
        variant={if has_filter?(@srql, "include_deleted", "true"), do: "soft", else: "ghost"}
      >
        <.icon name="hero-archive-box" class="size-3" /> Include deleted
      </.ui_button>
      <.ui_button
        :if={has_any_filter?(@srql)}
        navigate={~p"/devices"}
        size="xs"
        variant="ghost"
      >
        <.icon name="hero-x-mark" class="size-3" /> Clear
      </.ui_button>
    </div>

    <.composite_filters checks={@composite_checks} srql={@srql} />
    """
  end

  attr(:checks, :list, default: [])
  attr(:srql, :map, default: %{})

  # One chip per (check, verdict) rather than a select: every other quick filter
  # here is a `navigate` link, and a select would need an event handler to do
  # the same job. A check with no rules yet contributes nothing, which is
  # correct — it can produce no verdict to filter for.
  defp composite_filters(assigns) do
    ~H"""
    <div :if={@checks != []} class="mb-4 flex flex-wrap items-center gap-2">
      <span class="mr-1 text-xs font-medium text-sr-muted">Composite verdict:</span>

      <div :for={check <- @checks} class="flex flex-wrap items-center gap-2">
        <span :if={check.verdicts != []} class="text-xs text-sr-muted">{check.name}</span>

        <.ui_button
          :for={verdict <- check.verdicts}
          navigate={~p"/devices?q=#{CompositeCatalog.filter_query(check.slug, verdict)}"}
          size="xs"
          variant={
            if has_filter?(@srql, "composite.#{check.slug}", verdict), do: "primary", else: "ghost"
          }
        >
          {verdict}
        </.ui_button>
      </div>
    </div>
    """
  end
end
