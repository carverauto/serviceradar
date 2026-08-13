defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Stats do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Breakdown

  # Device Stats Cards Component
  attr(:stats, :map, required: true)
  attr(:loading, :boolean, default: false)

  def device_stats_cards(assigns) do
    stats = assigns.stats || %{}
    total = Map.get(stats, :total, 0)
    available = Map.get(stats, :available, 0)
    unavailable = Map.get(stats, :unavailable, 0)
    by_type = Map.get(stats, :by_type, [])
    by_vendor = Map.get(stats, :by_vendor, [])
    by_risk_level = Map.get(stats, :by_risk_level, [])
    new_today = Map.get(stats, :new_today, 0)
    new_last_7d = Map.get(stats, :new_last_7d, 0)
    new_last_30d = Map.get(stats, :new_last_30d, 0)

    # Get top items for display
    top_type = List.first(by_type)
    top_vendor = List.first(by_vendor)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:by_type, by_type)
      |> assign(:by_vendor, by_vendor)
      |> assign(:by_risk_level, by_risk_level)
      |> assign(:top_type, top_type)
      |> assign(:top_vendor, top_vendor)
      |> assign(:new_today, new_today)
      |> assign(:new_last_7d, new_last_7d)
      |> assign(:new_last_30d, new_last_30d)

    ~H"""
    <div class="mb-6">
      <div :if={@loading} class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <div
          :for={_ <- 1..3}
          class="rounded-xl border border-sr-line bg-sr-surface p-4 min-h-[7rem] animate-pulse"
        >
          <div class="h-4 bg-sr-subtle rounded w-1/2 mb-2" />
          <div class="h-6 bg-sr-subtle rounded w-3/4" />
        </div>
      </div>

      <div :if={not @loading} class="grid grid-cols-1 md:grid-cols-3 gap-3 items-stretch">
        <div class="rounded-xl border border-sr-line bg-sr-surface p-4 h-full min-h-[7rem]">
          <div class="flex items-start gap-3">
            <div class="p-2.5 rounded-lg bg-sr-brand/10 shrink-0">
              <.icon name="hero-server" class="size-5 text-sr-brand" />
            </div>
            <div class="min-w-0 flex-1 space-y-2">
              <div class="text-xs font-medium uppercase tracking-wide text-sr-muted">Devices</div>
              <div class="flex flex-wrap items-end gap-x-5 gap-y-2">
                <.link navigate={~p"/devices"} class="group block">
                  <div class="text-xl font-bold text-sr-ink group-hover:text-sr-brand">
                    {format_stat_number(@total)}
                  </div>
                  <div class="text-xs text-sr-muted">Total</div>
                </.link>
                <.link
                  navigate={~p"/devices?q=in:devices is_available:true"}
                  class="group block"
                >
                  <div class="flex items-baseline gap-1">
                    <span class={[
                      "text-xl font-bold",
                      if(@unavailable > 0, do: "text-error", else: "text-success")
                    ]}>
                      {format_stat_number(@available)}
                    </span>
                    <span :if={@unavailable > 0} class="text-sm text-error/80">
                      / {format_stat_number(@unavailable)} offline
                    </span>
                  </div>
                  <div class="text-xs text-sr-muted">
                    {if @unavailable == 0, do: "All online", else: "Available"}
                  </div>
                </.link>
              </div>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-[11px] leading-4 text-sr-muted">
                <span class="text-sr-ink/80">New</span>
                <.link
                  navigate={~p"/devices?q=in:devices first_seen:today"}
                  class="hover:text-sr-brand"
                >
                  today {format_stat_number(@new_today)}
                </.link>
                <.link
                  navigate={~p"/devices?q=in:devices first_seen:last_7d"}
                  class="hover:text-sr-brand"
                >
                  7d {format_stat_number(@new_last_7d)}
                </.link>
                <.link
                  navigate={~p"/devices?q=in:devices first_seen:last_30d"}
                  class="hover:text-sr-brand"
                >
                  30d {format_stat_number(@new_last_30d)}
                </.link>
              </div>
            </div>
          </div>
        </div>

        <!-- Top Device Type -->
        <Breakdown.device_breakdown_card
          title="By Type"
          items={@by_type}
          icon="hero-cpu-chip"
          kind="type"
          filter_field="type"
          empty_text="No type data"
        />

        <!-- Top Vendor -->
        <Breakdown.device_breakdown_card
          title="By Vendor"
          items={@by_vendor}
          icon="hero-building-office"
          kind="vendor"
          filter_field="vendor_name"
          empty_text="No vendor data"
        />
      </div>
    </div>
    """
  end

  def format_stat_number(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}k"
  end

  def format_stat_number(n) when is_integer(n), do: Integer.to_string(n)
  def format_stat_number(n) when is_float(n), do: n |> trunc() |> format_stat_number()
  def format_stat_number(_), do: "0"
end
