defmodule ServiceRadarWebNGWeb.MetricWindowComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query
  alias ServiceRadarWebNGWeb.SRQL.Builder

  @options [
    {"1h", "last_1h"},
    {"6h", "last_6h"},
    {"24h", "last_24h"},
    {"7d", "last_7d"},
    {"30d", "last_30d"},
    {"90d", "last_90d"}
  ]
  @ranges Enum.map(@options, &elem(&1, 1))

  def ranges, do: @ranges
  def normalize_range(range) when range in @ranges, do: range
  def normalize_range(_range), do: "last_24h"

  attr :id, :string, required: true
  attr :range, :string, required: true
  attr :event, :string, required: true
  attr :custom_event, :string, required: true
  attr :custom_options, :list, default: []
  attr :custom_enabled, :boolean, default: true

  def metric_window_controls(assigns) do
    form = to_form(%{"start" => "", "end" => "", "metric" => ""}, as: :window)
    assigns = assigns |> assign(:options, @options) |> assign(:form, form)

    ~H"""
    <div id={@id} class="flex flex-wrap items-center justify-end gap-2">
      <span class="text-[11px] uppercase tracking-wide text-sr-muted">Window</span>
      <div class="flex flex-wrap items-center gap-1">
        <.ui_button
          :for={{label, value} <- @options}
          id={"#{@id}-#{value}"}
          type="button"
          phx-click={@event}
          phx-value-range={value}
          size="xs"
          variant={if(@range == value, do: "primary", else: "ghost")}
          active={@range == value}
        >
          {label}
        </.ui_button>
        <button
          :if={not @custom_enabled}
          type="button"
          disabled
          class="px-2 py-1 text-xs text-sr-muted"
        >
          Custom
        </button>
        <details :if={@custom_enabled} id={"#{@id}-custom"} class="relative">
          <summary class="cursor-pointer rounded-sr-control px-2 py-1 text-xs text-sr-ink hover:bg-sr-subtle">
            Custom
          </summary>
          <div class="absolute right-0 z-30 mt-2 w-80 rounded-xl border border-sr-line bg-sr-surface p-4 shadow-lg">
            <.form for={@form} id={"#{@id}-custom-form"} phx-submit={@custom_event} class="space-y-3">
              <.input
                :if={@custom_options != []}
                field={@form[:metric]}
                type="select"
                label="Metric"
                options={@custom_options}
              />
              <.input field={@form[:start]} type="datetime-local" label="Start (UTC)" required />
              <.input field={@form[:end]} type="datetime-local" label="End (UTC)" required />
              <p class="text-xs text-sr-muted">Open this time range in the SRQL query editor.</p>
              <.ui_button type="submit" size="sm" variant="primary">Open SRQL</.ui_button>
            </.form>
          </div>
        </details>
      </div>
    </div>
    """
  end

  def custom_range(%{"start" => start_raw, "end" => end_raw}) do
    with {:ok, start_time} <- utc_input(start_raw),
         {:ok, end_time} <- utc_input(end_raw),
         :lt <- DateTime.compare(start_time, end_time) do
      {:ok, "[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}]"}
    else
      _ -> {:error, "Choose valid UTC dates with the end after the start."}
    end
  end

  def custom_range(_), do: {:error, "Choose a start and end date."}

  def query_for_range(query, range) do
    Builder.with_time_range(query, range, bucket: Query.bucket_for_time_range(range))
  end

  defp utc_input(value) when is_binary(value) do
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?$/, value),
         {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive(naive, "Etc/UTC")
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp utc_input(_), do: {:error, :invalid_date}
end
