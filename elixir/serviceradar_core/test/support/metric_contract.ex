defmodule ServiceRadar.TestSupport.MetricContract do
  @moduledoc """
  Checks a captured telemetry event against the metrics `ServiceRadar.Telemetry.metrics/0`
  defines for it.

  A Prometheus reporter drops an event that lacks a tag its metric declares, and leaves a
  gauge stale when the measurement is missing, so an event that drifts from its metric goes
  quiet without failing anything. A test that captured the event the code really emits can
  prove the metric still records it. It also ensures every numeric measurement the event
  carries is read by at least one defined metric.
  """

  import ExUnit.Assertions

  alias Telemetry.Metrics.Counter

  @doc """
  Asserts at least one metric is defined for `event` and that every metric it keeps finds
  each of its tags, as a scalar, and a numeric measurement. A counter counts the event and
  reads no measurement. Also asserts that every numeric measurement in `measurements` is
  the measurement of at least one non-counter metric for `event`.
  """
  @spec assert_exported([atom()], map(), map()) :: :ok
  def assert_exported(event, measurements, metadata) do
    metrics = Enum.filter(ServiceRadar.Telemetry.metrics(), &(&1.event_name == event))
    assert metrics != [], "no metric is defined for #{inspect(event)}"

    for metric <- metrics, keep?(metric, metadata, measurements) do
      tag_values = metric.tag_values.(metadata)

      for tag <- metric.tags do
        assert Map.has_key?(tag_values, tag),
               "#{inspect(metric.name)} lacks its tag #{inspect(tag)} in #{inspect(metadata)}"

        value = Map.fetch!(tag_values, tag)

        assert is_atom(value) or is_binary(value) or is_number(value),
               "#{inspect(metric.name)} has a non-scalar #{inspect(tag)}: #{inspect(value)}"
      end

      if !match?(%Counter{}, metric) do
        assert is_number(measure(metric.measurement, measurements, metadata)),
               "#{inspect(metric.name)} finds no number in #{inspect(measurements)}"
      end
    end

    for {key, value} <- measurements, is_atom(key), is_number(value) do
      assert Enum.any?(metrics, &(&1.measurement == key)),
             "#{inspect(key)} in #{inspect(event)} has no metric definition"
    end

    :ok
  end

  defp keep?(%{keep: nil}, _metadata, _measurements), do: true

  defp keep?(%{keep: keep}, metadata, _measurements) when is_function(keep, 1),
    do: keep.(metadata)

  defp keep?(%{keep: keep}, metadata, measurements) when is_function(keep, 2),
    do: keep.(metadata, measurements)

  defp measure(fun, measurements, _metadata) when is_function(fun, 1), do: fun.(measurements)

  defp measure(fun, measurements, metadata) when is_function(fun, 2),
    do: fun.(measurements, metadata)

  defp measure(key, measurements, _metadata), do: Map.get(measurements, key)
end
