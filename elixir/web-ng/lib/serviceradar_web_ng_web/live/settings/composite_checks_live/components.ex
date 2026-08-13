defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Components do
  @moduledoc """
  Presentation for the composite checks index and builder.

  Colour keys on `status`, never on `verdict`. Verdict slugs are operator
  authored, so any styling keyed to them is wrong on the next deployment;
  `status` is the fixed `healthy | degraded | down | unknown` enum and is what
  rollups, badges, and bars are safe to switch on.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.CompositeChecks.Rollup

  attr :entries, :list, required: true
  attr :can_manage, :boolean, default: false

  def check_list(assigns) do
    ~H"""
    <ul class="space-y-2">
      <li
        :for={entry <- @entries}
        class="rounded-sr-control border border-sr-border bg-sr-surface p-4"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <.link
                :if={@can_manage}
                navigate={~p"/settings/networks/composite-checks/#{entry.check.id}/edit"}
                class="truncate text-sm font-medium text-sr-ink hover:underline"
              >
                {entry.check.name}
              </.link>
              <span :if={!@can_manage} class="truncate text-sm font-medium text-sr-ink">
                {entry.check.name}
              </span>
              <.state_badge state={entry.check.state} />
            </div>

            <p class="mt-1 truncate font-mono text-xs text-sr-ink-muted">
              {entry.check.scope_query}
            </p>

            <p class="mt-1 text-xs text-sr-ink-muted">
              <span :if={entry.scope_count}>{entry.scope_count} devices in scope</span>
              <span :if={is_nil(entry.scope_count)}>Scope size unavailable</span>
            </p>
          </div>
        </div>

        <.verdict_rollup rollup={entry.rollup} />
      </li>
    </ul>
    """
  end

  attr :state, :atom, required: true

  def state_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-sr-control px-2 py-0.5 text-xs font-medium",
      @state == :enabled && "bg-emerald-500/10 text-emerald-400",
      @state == :draft && "bg-amber-500/10 text-amber-400",
      @state == :disabled && "bg-sr-surface-muted text-sr-ink-muted"
    ]}>
      {@state}
    </span>
    """
  end

  attr :rollup, :list, default: nil

  def verdict_rollup(assigns) do
    assigns = assign(assigns, :total, Rollup.total(assigns.rollup))

    ~H"""
    <p :if={is_nil(@rollup)} class="mt-3 text-xs text-sr-ink-muted">
      Not yet evaluated. Enable the check to start recording verdicts.
    </p>

    <div :if={@rollup} class="mt-3 space-y-2">
      <div class="flex h-1.5 overflow-hidden rounded-full bg-sr-surface-muted">
        <span
          :for={entry <- @rollup}
          class={["block", status_bar_class(entry.status)]}
          style={"width: #{percent(entry.count, @total)}%"}
          title={"#{entry.verdict}: #{entry.count}"}
        />
      </div>

      <ul class="flex flex-wrap gap-x-4 gap-y-1">
        <li :for={entry <- @rollup} class="flex items-center gap-1.5 text-xs">
          <span class={["size-1.5 rounded-full", status_bar_class(entry.status)]} />
          <span class="font-mono text-sr-ink">{entry.verdict}</span>
          <span class="text-sr-ink-muted">{entry.count}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: Float.round(count / total * 100, 2)

  defp status_bar_class(:healthy), do: "bg-emerald-500"
  defp status_bar_class(:degraded), do: "bg-amber-500"
  defp status_bar_class(:down), do: "bg-rose-500"
  defp status_bar_class(_status), do: "bg-sr-ink-muted"
end
