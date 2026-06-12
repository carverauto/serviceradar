defmodule ServiceRadar.Observability.AnomalyDetection.ContextEngineTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ContextEngine
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.RegistrySyncHelper

  setup_all do
    {:ok, _} = Application.ensure_all_started(:horde)
    {:ok, _pid} = RegistrySyncHelper.start_registry_unlinked(ProcessRegistry)

    :ok
  end

  setup do
    previous_reasoner = Application.get_env(:serviceradar_core, :anomaly_detection_reasoner)

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_reasoner,
      __MODULE__.CleanReasoner
    )

    on_exit(fn ->
      restore_env(:anomaly_detection_reasoner, previous_reasoner)
    end)

    :ok
  end

  test "routes a series through one Horde-registered owner" do
    series_key = "series-#{System.unique_integer([:positive])}"
    sample = sample(series_key, "e1", 1, 10.0)

    assert {:ok, %{state: "clean"}} = ContextEngine.evaluate(sample)
    assert [{pid, _metadata}] = ProcessRegistry.lookup(ContextEngine.registry_key(series_key))

    assert {:ok, %{state: "clean"}} =
             ContextEngine.evaluate(%{sample | event_id: "e2", order_key: {2, "e2"}, value: 11.0})

    assert [{^pid, _metadata}] = ProcessRegistry.lookup(ContextEngine.registry_key(series_key))
  end

  test "series ownership uses the deployment-wide Horde process registry" do
    series_key = "series-#{System.unique_integer([:positive])}"

    assert {:anomaly_context, ^series_key} = ContextEngine.registry_key(series_key)

    assert {:via, Horde.Registry, {ProcessRegistry, {:anomaly_context, ^series_key}}} =
             ContextEngine.via(series_key)
  end

  defmodule CleanReasoner do
    @moduledoc false
    def reason(_context, _sample) do
      {:ok, %{state: "clean", include_in_baseline: true, next_consecutive_anomalous: 0}}
    end
  end

  defp sample(series_key, event_id, order, value) do
    %{
      series_key: series_key,
      event_id: event_id,
      order_key: {order, event_id},
      value: value,
      observed_at_unix_nano: order,
      subject: "otel.metrics.derived",
      metric_class: "test"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
