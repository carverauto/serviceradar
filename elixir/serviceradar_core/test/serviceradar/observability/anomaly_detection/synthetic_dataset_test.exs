defmodule ServiceRadar.Observability.AnomalyDetection.SyntheticDatasetTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric, as: SrMetric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor
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

  test "encoded sysmon CPU fixture extracts and produces a confirmed anomaly" do
    values = [40.0, 40.4, 39.7, 40.2, 39.9, 40.1, 39.8, 40.3, 39.6, 40.0, 40.2, 39.9]
    anomalies = [88.0, 89.0, 90.0]
    series_key = "sysmon.cpu:sysmon:cpu:host-fixture:all"

    {:ok, owner} =
      ContextOwner.start_link(Keyword.put(@detector_opts, :series_key, series_key))

    try do
      values
      |> Enum.with_index(1)
      |> Enum.each(fn {value, index} ->
        [sample] = extract_cpu_fixture_sample(value, index)
        assert sample.series_key == series_key

        assert {:ok, verdict} = ContextOwner.evaluate(owner, sample)
        refute verdict.anomalous
        assert verdict.include_in_baseline
      end)

      verdicts =
        anomalies
        |> Enum.with_index(length(values) + 1)
        |> Enum.map(fn {value, index} ->
          [sample] = extract_cpu_fixture_sample(value, index)
          assert {:ok, verdict} = ContextOwner.evaluate(owner, sample)
          verdict
        end)

      assert [%{state: "pending_anomaly"}, %{state: "pending_anomaly"}, confirmed] = verdicts
      assert confirmed.state == "anomalous"
      assert confirmed.anomalous
      assert confirmed.breached
      assert confirmed.next_consecutive_anomalous == 3
    after
      stop_owner(owner)
    end
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

      assert ContextOwner.snapshot(owner).context.window_tail == dataset.normal

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
      refute Enum.any?(dataset.anomalous, &(&1 in snapshot.context.window_tail))
      assert snapshot.context.window_tail == dataset.normal

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

  describe "host_identity series keying (fixes [MINOR] 'unknown' collision)" do
    test "drops sysmon samples that lack a stable host identity instead of bucketing 'unknown'" do
      # No host_id / agent_id and no host_ip -> sample must be dropped so unrelated
      # unidentified hosts never collapse into a shared "unknown" Welford series.
      assert SampleExtractor.extract(
               sysmon_cpu_message(%{}, [%{"core_id" => "0", "usage_percent" => 42.0}])
             ) ==
               []

      assert SampleExtractor.extract(sysmon_memory_message(%{}, %{"used_percent" => 55.0})) == []

      assert SampleExtractor.extract(
               sysmon_disk_message(%{}, [%{"mount_point" => "/", "used_percent" => 60.0}])
             ) == []

      assert SampleExtractor.extract(sysmon_process_message(%{}, [%{}, %{}])) == []
    end

    test "two unidentified hosts do not merge into one series_key" do
      # Distinct payloads with no stable id must both be dropped -> no shared key.
      assert SampleExtractor.extract(
               sysmon_cpu_message(%{}, [%{"core_id" => "0", "usage_percent" => 10.0}])
             ) == []

      assert SampleExtractor.extract(
               sysmon_cpu_message(%{}, [%{"core_id" => "0", "usage_percent" => 99.0}])
             ) == []
    end

    test "stable host_id still produces per-core and per-mount series" do
      [core0, core1] =
        SampleExtractor.extract(
          sysmon_cpu_message(%{"host_id" => "host-a"}, [
            %{"core_id" => "0", "usage_percent" => 42.0},
            %{"core_id" => "1", "usage_percent" => 43.0}
          ])
        )

      assert core0.series_key == "sysmon.cpu:sysmon:cpu:host-a:0"
      assert core1.series_key == "sysmon.cpu:sysmon:cpu:host-a:1"

      [root, var] =
        SampleExtractor.extract(
          sysmon_disk_message(%{"host_id" => "host-a"}, [
            %{"mount_point" => "/", "used_percent" => 60.0},
            %{"mount_point" => "/var", "used_percent" => 70.0}
          ])
        )

      assert root.series_key == "sysmon.disk:sysmon:disk:host-a:/"
      assert var.series_key == "sysmon.disk:sysmon:disk:host-a:/var"
    end

    test "prefers a stable agent_id over host_ip and does not tag instability" do
      [sample] =
        SampleExtractor.extract(
          sysmon_memory_message(
            %{"agent_id" => "agent-7", "host_ip" => "10.0.0.5"},
            %{"used_percent" => 55.0}
          )
        )

      # Stable id wins; DHCP IP changes must not re-key the series.
      assert sample.series_key == "sysmon.memory:sysmon:memory:agent-7"
      refute Map.get(sample.metadata, "host_identity_unstable")
    end

    test "falls back to host_ip only when no stable id exists and tags instability" do
      [sample] =
        SampleExtractor.extract(
          sysmon_memory_message(%{"host_ip" => "10.0.0.5"}, %{"used_percent" => 55.0})
        )

      assert sample.series_key == "sysmon.memory:sysmon:memory:10.0.0.5"
      assert sample.metadata["host_identity_unstable"] == "true"
    end
  end

  defp sysmon_cpu_message(identity, cpus) do
    sysmon_message("cpu", Map.put(identity, "cpus", cpus))
  end

  defp extract_cpu_fixture_sample(value, index) do
    SampleExtractor.extract(
      sysmon_cpu_message(
        %{"host_id" => "host-fixture", "timestamp" => 1_700_000_000_000_000_000 + index},
        [%{"core_id" => "all", "usage_percent" => value}]
      )
    )
  end

  defp sysmon_memory_message(identity, memory) do
    sysmon_message("memory", Map.put(identity, "memory", memory))
  end

  defp sysmon_disk_message(identity, disks) do
    sysmon_message("disk", Map.put(identity, "disks", disks))
  end

  defp sysmon_process_message(identity, processes) do
    sysmon_message("process", Map.put(identity, "processes", processes))
  end

  defp sysmon_message(family, sample) do
    observed_at = Map.get(sample, "timestamp", 1_700_000_000_000_000_000)
    {host_identity, unstable?} = host_identity(sample)

    data =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{
          agent_id: Map.get(sample, "agent_id", ""),
          gateway_id: "gateway-1",
          partition: "default",
          service_name: "sysmon",
          service_type: "sysmon",
          host_id: Map.get(sample, "host_id", ""),
          host_ip: Map.get(sample, "host_ip", "")
        },
        ingest_identity: %IngestIdentity{
          source: "sysmon-metrics",
          payload_kind: "serviceradar.metric.v1",
          producer_id: Map.get(sample, "agent_id", ""),
          producer_kind: "agent"
        },
        emitted_at_unix_nano: observed_at,
        metrics: sysmon_metrics(family, sample, host_identity, unstable?, observed_at)
      })

    %{data: data, metadata: %{subject: "metrics.sysmon.#{family}"}}
  end

  defp sysmon_metrics("cpu", %{"cpus" => cpus}, host_identity, unstable?, observed_at) do
    Enum.map(cpus, fn cpu ->
      core_id = Map.get(cpu, "core_id", "all")

      sysmon_metric(
        "usage_percent",
        "sysmon.cpu",
        Map.get(cpu, "usage_percent"),
        observed_at,
        host_identity,
        "sysmon:cpu:#{host_identity}:#{core_id}",
        unstable?,
        %{"core_id" => core_id}
      )
    end)
  end

  defp sysmon_metrics("memory", %{"memory" => memory}, host_identity, unstable?, observed_at) do
    [
      sysmon_metric(
        "used_percent",
        "sysmon.memory",
        Map.get(memory, "used_percent"),
        observed_at,
        host_identity,
        "sysmon:memory:#{host_identity}",
        unstable?,
        %{}
      )
    ]
  end

  defp sysmon_metrics("disk", %{"disks" => disks}, host_identity, unstable?, observed_at) do
    Enum.map(disks, fn disk ->
      mount = Map.get(disk, "mount_point", "unknown")

      sysmon_metric(
        "used_percent",
        "sysmon.disk",
        Map.get(disk, "used_percent"),
        observed_at,
        host_identity,
        "sysmon:disk:#{host_identity}:#{mount}",
        unstable?,
        %{"mount_point" => mount}
      )
    end)
  end

  defp sysmon_metrics(
         "process",
         %{"processes" => processes},
         host_identity,
         unstable?,
         observed_at
       ) do
    Enum.map(processes, fn process ->
      process_name = Map.get(process, "name", "unknown")

      sysmon_metric(
        "process_count",
        "sysmon.process",
        Map.get(process, "count", 1.0),
        observed_at,
        host_identity,
        "sysmon:process:#{host_identity}:#{process_name}",
        unstable?,
        %{"process_name" => process_name}
      )
    end)
  end

  defp sysmon_metrics(_family, _sample, _host_identity, _unstable?, _observed_at), do: []

  defp sysmon_metric(
         name,
         metric_type,
         value,
         observed_at,
         host_identity,
         series_identity,
         unstable?,
         attributes
       ) do
    %SrMetric{
      name: name,
      metric_type: metric_type,
      kind: :METRIC_KIND_GAUGE,
      unit: "%",
      tags: entries(attributes),
      metadata: entries(host_metadata(host_identity, unstable?)),
      points: [
        %MetricPoint{
          value: numeric_value(value),
          raw_value: to_string(value),
          raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
          observed_at_unix_nano: observed_at,
          series_identity_hint: if(host_identity, do: series_identity, else: "")
        }
      ]
    }
  end

  defp host_identity(%{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {agent_id, false}

  defp host_identity(%{"host_id" => host_id}) when is_binary(host_id) and host_id != "",
    do: {host_id, false}

  defp host_identity(%{"host_ip" => host_ip}) when is_binary(host_ip) and host_ip != "",
    do: {host_ip, true}

  defp host_identity(_sample), do: {nil, false}

  defp host_metadata(nil, _unstable?), do: %{}

  defp host_metadata(host_identity, true),
    do: %{"host_identity" => host_identity, "host_identity_unstable" => true}

  defp host_metadata(host_identity, false), do: %{"host_identity" => host_identity}

  defp numeric_value(value) when is_number(value), do: value * 1.0
  defp numeric_value(_value), do: 0.0

  defp entries(map) do
    Enum.map(map, fn {key, value} -> %StringMapEntry{key: key, value: to_string(value)} end)
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
