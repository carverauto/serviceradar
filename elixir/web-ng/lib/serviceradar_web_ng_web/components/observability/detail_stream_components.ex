defmodule ServiceRadarWebNGWeb.Observability.DetailStreamComponents do
  @moduledoc """
  Shared master-detail stream chrome for observability detail LiveViews
  (logs, events, and future peers).

  Entries are maps with the keys:

  * `:id` - stable entry id (used for selection + DOM id)
  * `:dom_id` - stable unique DOM identity supplied by the stream caller
  * `:href` - navigate path for the entry
  * `:severity` - raw severity value for the status dot / filters
  * `:secondary` - right-hand meta (service name, host, provider, …)
  * `:timestamp` - canonical absolute instant
  * `:preview` - one-line body preview
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1, user_time: 1]
  import ServiceRadarWebNGWeb.UIComponents

  @severity_chip_labels %{
    "all" => "All",
    "info" => "Info",
    "warn" => "Warn",
    "warning" => "Warn",
    "error" => "Err",
    "debug" => "Dbg",
    "critical" => "Crit",
    "high" => "High",
    "medium" => "Med",
    "low" => "Low"
  }

  attr :id, :string, default: "detail-stream"
  attr :title, :string, required: true
  attr :entries, :list, required: true
  attr :timezone, :string, required: true
  attr :page, :integer, required: true
  attr :page_count, :integer, required: true
  attr :selected_id, :string, required: true
  attr :stream_severity, :string, required: true
  attr :severity_filters, :list, required: true
  attr :stream_query, :any, default: nil
  attr :context_label, :any, default: nil
  attr :has_prev, :boolean, default: false
  attr :has_next, :boolean, default: false
  attr :empty_label, :string, default: "No matching entries"
  attr :class, :any, default: nil

  @doc """
  Desktop-only side rail of related stream entries with severity chips and pagination.
  """
  def detail_stream_pane(assigns) do
    ~H"""
    <aside
      id={@id}
      class={[
        "sr-detail-stream hidden min-h-0 min-w-0 max-w-full flex-col overflow-hidden border-sr-line bg-sr-surface lg:flex",
        @class
      ]}
    >
      <div class="min-w-0 shrink-0 space-y-2 border-b border-sr-line px-2.5 py-2.5">
        <div class="flex items-center justify-between gap-2">
          <h2 class="text-sm font-semibold tracking-tight text-sr-ink">{@title}</h2>
          <span class="font-mono text-xs text-sr-muted">
            {if @page_count > 0, do: "p.#{@page}", else: "0"}
          </span>
        </div>

        <div
          :if={is_binary(@context_label) and @context_label != ""}
          class="truncate text-[11px] text-sr-muted"
          title={@context_label}
        >
          {@context_label}
        </div>

        <div
          :if={is_binary(@stream_query) and @stream_query != ""}
          class="truncate rounded-sr-control border border-sr-line bg-sr-subtle/50 px-2 py-1 font-mono text-[11px] text-sr-muted"
          title={@stream_query}
        >
          {@stream_query}
        </div>

        <div class="flex flex-nowrap items-center gap-0.5 overflow-x-auto">
          <.stream_severity_chip
            :for={sev <- @severity_filters}
            severity={sev}
            active={@stream_severity == sev}
          />
        </div>
      </div>

      <div class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain">
        <div :if={@entries == []} class="px-3 py-6 text-center text-sm text-sr-muted">
          {@empty_label}
        </div>

        <.link
          :for={entry <- @entries}
          navigate={entry.href}
          id={"stream-" <> entry.dom_id}
          class={[
            "group relative block min-w-0 border-b border-sr-line/70 px-2.5 py-2 transition-colors duration-150 ease-sr-out",
            entry.id == @selected_id && "bg-sr-subtle",
            entry.id != @selected_id && "hover:bg-sr-subtle/60"
          ]}
        >
          <div
            :if={entry.id == @selected_id}
            class="absolute inset-y-0 left-0 w-0.5 bg-sr-brand"
          >
          </div>
          <div class="flex min-w-0 items-start gap-2">
            <span class={[
              "mt-1 size-1.5 shrink-0 rounded-full",
              severity_dot_class(entry.severity)
            ]}></span>
            <div class="min-w-0 flex-1 overflow-hidden">
              <div class="flex min-w-0 items-baseline justify-between gap-2">
                <.user_time
                  id={"#{@id}-#{entry.dom_id}-time"}
                  value={entry.timestamp}
                  timezone={@timezone}
                  style={:compact}
                  fallback="—"
                  class="shrink-0 font-mono text-[11px] text-sr-muted"
                />
                <span class="truncate font-mono text-[10px] text-sr-muted">{entry.secondary}</span>
              </div>
              <p class="mt-0.5 truncate text-xs leading-snug text-sr-ink">{entry.preview}</p>
            </div>
          </div>
        </.link>
      </div>

      <div class="flex shrink-0 items-center justify-between gap-1 border-t border-sr-line px-2 py-1.5">
        <.ui_button
          type="button"
          size="xs"
          variant="outline"
          phx-click="stream_prev"
          disabled={not @has_prev}
        >
          <.icon name="hero-chevron-left" class="size-3.5" /> Prev
        </.ui_button>
        <span class="font-mono text-[11px] text-sr-muted">{@page}</span>
        <.ui_button
          type="button"
          size="xs"
          variant="outline"
          phx-click="stream_next"
          disabled={not @has_next}
        >
          Next <.icon name="hero-chevron-right" class="size-3.5" />
        </.ui_button>
      </div>
    </aside>
    """
  end

  attr :severity, :string, required: true
  attr :active, :boolean, default: false

  def stream_severity_chip(assigns) do
    label = Map.get(@severity_chip_labels, assigns.severity) || String.upcase(assigns.severity)
    assigns = assign(assigns, :label, label)

    ~H"""
    <.ui_button
      type="button"
      size="xs"
      variant={if(@active, do: "soft", else: "ghost")}
      active={@active}
      phx-click="set_stream_severity"
      phx-value-severity={@severity}
      class="!min-h-6 h-6 shrink-0 px-1.5 text-[10px] font-medium leading-none tracking-wide"
    >
      {@label}
    </.ui_button>
    """
  end

  @doc """
  Filter stream entries by a severity chip selection.

  * `:logs` - log severity vocabulary (info/warn/error/debug)
  * `:events` - OCSF-ish severity vocabulary (critical/high/medium/low/info)
  """
  def filter_stream_entries(entries, "all", _mode) when is_list(entries), do: entries

  def filter_stream_entries(entries, severity, :logs) when is_list(entries) do
    target = normalize_severity(severity)

    Enum.filter(entries, fn entry ->
      s = normalize_severity(entry.severity)

      cond do
        target in ["warn", "warning"] -> s in ["warn", "warning", "high"]
        target == "error" -> s in ["error", "critical", "fatal"]
        true -> s == target
      end
    end)
  end

  def filter_stream_entries(entries, severity, :events) when is_list(entries) do
    target = normalize_severity(severity)

    Enum.filter(entries, fn entry ->
      s = normalize_severity(entry.severity)

      cond do
        target == "critical" -> s in ["critical", "fatal"]
        target == "high" -> s in ["high", "error", "warn", "warning"]
        target == "medium" -> s in ["medium"]
        target == "low" -> s in ["low"]
        target == "info" -> s in ["info", "informational", "debug", "ok"]
        true -> s == target
      end
    end)
  end

  def filter_stream_entries(entries, severity, :alerts) when is_list(entries) do
    target = normalize_severity(severity)

    Enum.filter(entries, fn entry ->
      s = normalize_severity(entry.severity)

      cond do
        target == "critical" -> s in ["critical", "emergency", "error", "fatal"]
        target == "warning" -> s in ["warning", "warn", "high"]
        target == "info" -> s in ["info", "informational", "medium", "low"]
        true -> s == target
      end
    end)
  end

  def filter_stream_entries(entries, _severity, _mode) when is_list(entries), do: entries
  def filter_stream_entries(_, _, _), do: []

  defp severity_dot_class(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "bg-rose-500"
      s when s in ["high", "warn", "warning"] -> "bg-amber-400"
      s when s in ["medium", "info", "informational"] -> "bg-sr-brand"
      s when s in ["low", "debug", "trace", "ok"] -> "bg-sky-400"
      _ -> "bg-sr-muted"
    end
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()
end
