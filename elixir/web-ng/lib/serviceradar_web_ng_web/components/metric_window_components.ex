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

  # SRQL refuses a window longer than this; refuse it at the form instead, where
  # the message can say why.
  @max_span_days 395

  @default_range "last_24h"

  def ranges, do: @ranges
  def default_range, do: @default_range
  def normalize_range(range) when range in @ranges, do: range
  def normalize_range(_range), do: @default_range

  attr :id, :string, required: true
  attr :range, :string, required: true
  attr :event, :string, required: true
  attr :custom_event, :string, required: true
  attr :custom_options, :list, default: []
  attr :custom_enabled, :boolean, default: true
  attr :custom_submit_label, :string, default: "Open SRQL"
  attr :custom_hint, :string, default: "Open this time range in the SRQL query editor."

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
          <summary class={[
            "cursor-pointer rounded-sr-control px-2 py-1 text-xs text-sr-ink hover:bg-sr-subtle",
            absolute_range?(@range) && "bg-sr-subtle font-semibold"
          ]}>
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
              <p class="text-xs text-sr-muted">{@custom_hint}</p>
              <.ui_button type="submit" size="sm" variant="primary">{@custom_submit_label}</.ui_button>
            </.form>
          </div>
        </details>
      </div>
    </div>
    """
  end

  @doc """
  Turns the custom form's UTC inputs into an absolute `[start,end]` range.

  `:max_days` is the longest span the caller's queries can serve. It defaults to
  what SRQL allows a rollup-eligible metric query; a page whose queries are not
  rollup-eligible passes SRQL's shorter limit.
  """
  def custom_range(params, opts \\ [])

  def custom_range(%{"start" => start_raw, "end" => end_raw}, opts) do
    max_days = Keyword.get(opts, :max_days, @max_span_days)

    with {:ok, start_time} <- utc_input(start_raw),
         {:ok, end_time} <- utc_input(end_raw),
         {:span, true} <- {:span, within_max_span?(start_time, end_time, max_days)},
         :lt <- DateTime.compare(start_time, end_time) do
      {:ok, "[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}]"}
    else
      {:span, false} -> {:error, "Choose a range of #{max_days} days or less."}
      _ -> {:error, "Choose valid UTC dates with the end after the start."}
    end
  end

  def custom_range(_params, _opts), do: {:error, "Choose a start and end date."}

  @doc """
  Whether `range` is a well-formed absolute `[start,end]` window, as produced by
  `custom_range/1`: two ISO 8601 instants with the end after the start.

  A page that lets a range arrive from the client checks it here before it goes
  anywhere near a query, since the relative windows are an allowlist and an
  absolute one cannot be.
  """
  @spec absolute_range?(term()) :: boolean()
  def absolute_range?(range), do: match?({:ok, _start, _end}, absolute_bounds(range))

  @doc "The two instants of a well-formed absolute range, for showing it to a person."
  @spec absolute_bounds(term()) :: {:ok, DateTime.t(), DateTime.t()} | :error
  def absolute_bounds("[" <> _ = range) do
    with true <- String.ends_with?(range, "]"),
         [start_raw, end_raw] <- range |> String.slice(1..-2//1) |> String.split(",", parts: 2),
         {:ok, start_time, 0} <- DateTime.from_iso8601(start_raw),
         {:ok, end_time, 0} <- DateTime.from_iso8601(end_raw),
         true <- DateTime.before?(start_time, end_time),
         true <- within_max_span?(start_time, end_time) do
      {:ok, start_time, end_time}
    else
      _ -> :error
    end
  end

  def absolute_bounds(_range), do: :error

  defp within_max_span?(start_time, end_time, max_days \\ @max_span_days) do
    DateTime.diff(end_time, start_time, :second) <= max_days * 86_400
  end

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
