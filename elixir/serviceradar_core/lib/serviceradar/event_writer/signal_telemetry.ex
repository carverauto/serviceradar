defmodule ServiceRadar.EventWriter.SignalTelemetry do
  @moduledoc """
  Per-signal EventWriter counters.

  Emits `[:serviceradar, :event_writer, :signal]` telemetry events with a
  `%{count: n}` measurement and `%{signal: signal, outcome: outcome}`
  metadata so dashboards can track decode/insert/drop volume per signal.

  Outcomes:

  - `:received` — messages handed to a processor batch
  - `:written`  — rows actually inserted
  - `:rejected` — messages dropped because they could not be decoded

  Signals: `:logs`, `:traces`, `:metrics` (span-derived samples), and
  `:metric_points` (OTLP data points).
  """

  @event [:serviceradar, :event_writer, :signal]
  @signals [:logs, :traces, :metrics, :metric_points]
  @outcomes [:received, :written, :rejected]

  @doc "Telemetry event name for per-signal counters."
  @spec event() :: [atom()]
  def event, do: @event

  @doc """
  Emits a per-signal counter. Zero counts are skipped so dashboards only
  see real increments.
  """
  @spec emit(atom(), atom(), non_neg_integer()) :: :ok
  def emit(signal, outcome, count)
      when signal in @signals and outcome in @outcomes and is_integer(count) do
    if count > 0 do
      :telemetry.execute(@event, %{count: count}, %{signal: signal, outcome: outcome})
    end

    :ok
  end
end
