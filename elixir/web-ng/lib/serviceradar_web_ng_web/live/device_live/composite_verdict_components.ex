defmodule ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictComponents do
  @moduledoc """
  The composite check verdicts recorded for a device.

  Colour keys on `status`, never on `verdict`: verdict slugs are operator
  authored, so styling keyed to them is wrong on the next deployment. `status`
  is the fixed `healthy | degraded | down | unknown` enum.
  """

  use ServiceRadarWebNGWeb, :html

  attr(:entries, :list, default: [])

  def composite_verdict_section(assigns) do
    ~H"""
    <div :if={@entries != []} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center gap-2">
          <.icon name="hero-shield-check" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Composite Checks</span>
          <span class="text-xs text-sr-muted">({length(@entries)})</span>
        </div>
      </div>

      <div class="space-y-3 p-4">
        <.composite_verdict_entry :for={entry <- @entries} entry={entry} />
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)

  defp composite_verdict_entry(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-sr-line p-3"
      data-composite-check={@entry.check_slug}
      data-composite-verdict={@entry.verdict}
      data-composite-status={@entry.status}
    >
      <div class="flex flex-wrap items-center gap-2">
        <.link
          navigate={~p"/settings/networks/composite-checks/#{@entry.check_id}/edit"}
          class="text-sm font-medium text-sr-ink hover:underline"
        >
          {@entry.check_name}
        </.link>

        <span class={["size-1.5 rounded-full", status_dot_class(@entry.status)]} />
        <span class="font-mono text-xs text-sr-ink">{@entry.verdict_label}</span>

        <.ui_badge :if={@entry.check_state != :enabled} size="xs" variant="warning">
          {@entry.check_state}
        </.ui_badge>

        <span class="ml-auto text-xs text-sr-muted">
          {"evaluated #{relative(@entry.evaluated_at)}"}
        </span>
      </div>

      <p :if={@entry.explanation} class="mt-1 text-xs text-sr-muted">{@entry.explanation}</p>

      <ul class="mt-2 space-y-1">
        <li
          :for={input <- @entry.inputs}
          class="flex flex-wrap items-center gap-2 text-xs"
          data-composite-input={input.key}
          data-composite-value={input.value}
          data-composite-age={input.age}
          data-composite-reason={input.reason}
        >
          <span class="text-sr-muted">{input.label}</span>

          <span class={["font-mono", input.stale && "text-amber-400", !input.stale && "text-sr-ink"]}>
            {input.value}
          </span>

          <span :if={input.expected} class="text-sr-muted">
            {"expected #{input.expected}"}
          </span>

          <span class="text-sr-muted">{input.age}</span>
          <span :if={input.stale} class="text-amber-400">stale</span>

          <span :if={input.reason} class="font-mono text-sr-muted">{input.reason}</span>

          <span :if={input.removed} class="text-sr-muted">
            no longer part of this check
          </span>
        </li>
      </ul>
    </div>
    """
  end

  # The result stores a UTC timestamp; the device page renders wall-clock ages
  # everywhere else, so this matches rather than inventing a second convention.
  defp relative(nil), do: "never"

  defp relative(%DateTime{} = at) do
    ServiceRadarWebNGWeb.CompositeChecks.Snapshot.age(at, DateTime.utc_now())
  end

  defp status_dot_class(:healthy), do: "bg-emerald-500"
  defp status_dot_class(:degraded), do: "bg-amber-500"
  defp status_dot_class(:down), do: "bg-rose-500"
  defp status_dot_class(_status), do: "bg-sr-muted"
end
