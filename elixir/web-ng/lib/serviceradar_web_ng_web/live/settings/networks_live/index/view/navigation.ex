defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Navigation do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :active_tab, :atom, required: true
  attr :running_count, :integer, default: 0

  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-sr-line">
      <button
        phx-click="switch_tab"
        phx-value-tab="groups"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :groups, do: "border-sr-brand text-sr-brand", else: "border-transparent text-sr-muted hover:text-sr-ink")}
      >
        Sweep Groups
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :profiles, do: "border-sr-brand text-sr-brand", else: "border-transparent text-sr-muted hover:text-sr-ink")}
      >
        Scanner Profiles
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="active_scans"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors flex items-center gap-1.5 " <>
               if(@active_tab == :active_scans, do: "border-sr-brand text-sr-brand", else: "border-transparent text-sr-muted hover:text-sr-ink")}
      >
        Active Scans
        <span
          :if={@running_count > 0}
          class="inline-flex items-center justify-center px-1.5 py-0.5 text-xs font-semibold rounded-full bg-success text-success-content animate-pulse"
        >
          {@running_count}
        </span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="cleanup"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :cleanup, do: "border-sr-brand text-sr-brand", else: "border-transparent text-sr-muted hover:text-sr-ink")}
      >
        Inventory Cleanup
      </button>
    </div>
    """
  end

  # Discovery Jobs Panel
end
