defmodule ServiceRadar.Observability.AnomalyDetection.SyntheticDatasetTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
  alias ServiceRadar.Observability.CausalReasoner

  @detector_opts [
    min_samples: 10,
    window_size: 12,
    n_sigma: 3.0,
    confirm_slots: 3,
    suppress_until_warmed?: false,
    baseline_seed_opts: [enabled: false],
    checkpoint_store: __MODULE__.NoopCheckpoint,
    checkpoint_flush_interval_ms: 0,
    reasoner: CausalReasoner,
    name: nil
  ]

  @datasets [
    %{
      name: "cpu",
      series_key: "sysmon:cpu:host-a:all",
      subject: "metrics.sysmon.cpu",
      metric_class: "sysmon.cpu",
      metadata: %{"host_id" => "host-a", "metric_name" => "usage_percent"},
      normal: [40.0, 40.4, 39.7, 40.2, 39.9, 40.1, 39.8, 40.3, 39.6, 40.0, 40.2, 39.9],
      anomalous: [88.0, 89.0, 90.0],
      recovery: 40.1
    },
    %{
      name: "memory",
      series_key: "sysmon:memory:host-a",
      subject: "metrics.sysmon.memory",
      metric_class: "sysmon.memory",
      metadata: %{"host_id" => "host-a", "metric_name" => "used_percent"},
      normal: [55.0, 55.3, 54.8, 55.1, 55.2, 54.9, 55.4, 55.0, 54.7, 55.1, 55.2, 54.9],
      anomalous: [93.0, 94.0, 95.0],
      recovery: 55.0
    },
    %{
      name: "disk",
      series_key: "sysmon:disk:host-a:/var",
      subject: "metrics.sysmon.disk",
      metric_class: "sysmon.disk",
      metadata: %{"host_id" => "host-a", "mount_point" => "/var", "metric_name" => "used_percent"},
      normal: [62.0, 62.2, 61.8, 62.1, 62.3, 61.9, 62.0, 62.2, 61.7, 62.1, 62.0, 61.9],
      anomalous: [88.0, 89.0, 90.0],
      recovery: 62.0
    },
    %{
      name: "network activity",
      series_key: "flow:flows.raw.netflow:router-a:10.0.0.1:10.0.0.2:6",
      subject: "flows.raw.netflow",
      metric_class: "flow",
      metadata: %{
        "sampler_address" => "router-a",
        "src_addr" => "10.0.0.1",
        "dst_addr" => "10.0.0.2",
        "protocol" => "6",
        "metric_name" => "bytes"
      },
      normal: [
        1_000.0,
        1_030.0,
        980.0,
        1_020.0,
        990.0,
        1_010.0,
        1_040.0,
        970.0,
        1_000.0,
        1_025.0,
        995.0,
        1_015.0
      ],
      anomalous: [5_000.0, 5_100.0, 5_200.0],
      recovery: 1_005.0
    }
  ]

  test "detects sustained synthetic CPU, memory, disk, and network anomalies" do
    Enum.each(@datasets, &assert_dataset_detects_sustained_anomaly/1)
  end

  defp assert_dataset_detects_sustained_anomaly(dataset) do
    {:ok, owner} =
      ContextOwner.start_link(Keyword.put(@detector_opts, :series_key, dataset.series_key))

    try do
      dataset.normal
      |> Enum.with_index(1)
      |> Enum.each(fn {value, index} ->
        assert {:ok, verdict} =
                 ContextOwner.evaluate(owner, sample(dataset, "normal-#{index}", index, value))

        refute verdict.anomalous,
               "#{dataset.name} baseline sample #{index} should not be anomalous"

        assert verdict.include_in_baseline
      end)

      assert ContextOwner.snapshot(owner).context.baseline == dataset.normal

      [first, second, third] =
        dataset.anomalous
        |> Enum.with_index(length(dataset.normal) + 1)
        |> Enum.map(fn {value, index} ->
          assert {:ok, verdict} =
                   ContextOwner.evaluate(owner, sample(dataset, "anomaly-#{index}", index, value))

          verdict
        end)

      assert first.state == "pending_anomaly"
      assert first.breached
      refute first.anomalous
      refute first.include_in_baseline
      assert first.next_consecutive_anomalous == 1

      assert second.state == "pending_anomaly"
      assert second.breached
      refute second.anomalous
      refute second.include_in_baseline
      assert second.next_consecutive_anomalous == 2

      assert third.state == "anomalous"
      assert third.breached
      assert third.anomalous
      refute third.include_in_baseline
      assert third.next_consecutive_anomalous == 3
      assert third.score >= 3.0

      snapshot = ContextOwner.snapshot(owner)
      refute Enum.any?(dataset.anomalous, &(&1 in snapshot.context.baseline))
      assert snapshot.context.baseline == dataset.normal

      recovery_index = length(dataset.normal) + length(dataset.anomalous) + 1

      assert {:ok, recovery} =
               ContextOwner.evaluate(
                 owner,
                 sample(dataset, "recovery", recovery_index, dataset.recovery)
               )

      assert recovery.state == "clean"
      refute recovery.anomalous
      refute recovery.breached
      assert recovery.include_in_baseline
      assert recovery.next_consecutive_anomalous == 0
    after
      stop_owner(owner)
    end
  end

  defp sample(dataset, event_id, order, value) do
    %{
      series_key: dataset.series_key,
      event_id: "#{dataset.name}:#{event_id}",
      order_key: {order, event_id},
      value: value,
      observed_at_unix_nano: order,
      subject: dataset.subject,
      metric_class: dataset.metric_class,
      metadata: dataset.metadata
    }
  end

  defp stop_owner(owner) do
    if Process.alive?(owner), do: GenServer.stop(owner)
  catch
    :exit, _reason -> :ok
  end

  defmodule NoopCheckpoint do
    @moduledoc false

    def load(_series_key, _opts), do: {:ok, nil}
    def save(_series_key, _checkpoint, _opts), do: :ok
  end
end
