defmodule ServiceRadar.Edge.SweepHostMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepHostMetrics
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepIcmpSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Edge.V1.SweepOpenPortV1
  alias Serviceradar.Edge.V1.SweepTcpSummaryV1
  alias Serviceradar.Edge.V1.SweepTestV1
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Observability.MetricEnvelope

  @execution_id "0b9d2f6e-4c1a-4e0b-9a51-3f2d8c7e1a01"
  @group_id "5e3c1a7b-2d4f-4a8e-b6c0-9f1e2d3c4b02"
  @event_id "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c04"
  @agent_id "agent-test-leased01"
  @observed_at 1_781_222_400_000_000_000

  # Check indexes: 0 ICMP, 1 TCP 22, 2 TCP 443.
  @checks [
    %SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0},
    %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 22},
    %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}
  ]

  defp identity do
    %{
      agent_id: @agent_id,
      gateway_id: "gateway-test01",
      partition: "default",
      event_id: @event_id
    }
  end

  defp host(octet, fields) do
    struct!(
      %SweepHostObservationV1{
        address: <<192, 0, 2, octet>>,
        observed_at_delta_nano: octet * 1_000,
        tcp: %SweepTcpSummaryV1{outcome: :SWEEP_MODE_OUTCOME_SUCCESS, tested_count: 2}
      },
      fields
    )
  end

  defp batch(hosts) do
    %SweepObservationBatchV1{
      execution_id: Ecto.UUID.dump!(@execution_id),
      sweep_group_id: Ecto.UUID.dump!(@group_id),
      observed_at_unix_nano: @observed_at,
      tested_checks: @checks,
      hosts: hosts
    }
  end

  defp stored_rows(metric_batches) do
    Enum.flat_map(metric_batches, fn metric_batch ->
      {:ok, rows, _count} =
        metric_batch |> MetricBatch.encode() |> MetricEnvelope.decode_rows_count()

      rows
    end)
  end

  defp values(rows, name) do
    for row <- rows, row.metric_name == name, into: %{} do
      {{row.target_device_ip, row.tags["port"]}, row.value}
    end
  end

  test "every host of a leased batch yields the stored per-host rows of an unleased sweep" do
    hosts = [
      # ICMP answers, 443 open.
      host(10,
        hostname: "host01.example.com",
        icmp: %SweepIcmpSummaryV1{
          outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
          target_reached: true,
          round_trip_micro: 1_500,
          packet_loss_pct: 0.0
        },
        open_ports: [
          %SweepOpenPortV1{tested_check_index: 2, response_time_nano: 2_000_000, service: "https"}
        ]
      ),
      # Nothing answers.
      host(11,
        icmp: %SweepIcmpSummaryV1{
          outcome: :SWEEP_MODE_OUTCOME_FAILURE,
          target_reached: false,
          packet_loss_pct: 100.0
        }
      ),
      # ICMP blocked, but 22 is open: available, as the projection stores it.
      host(12,
        icmp: %SweepIcmpSummaryV1{outcome: :SWEEP_MODE_OUTCOME_FAILURE, target_reached: false},
        open_ports: [%SweepOpenPortV1{tested_check_index: 1}]
      )
    ]

    rows = hosts |> batch() |> SweepHostMetrics.build(identity()) |> stored_rows()

    assert values(rows, "sweep.host.available") == %{
             {"192.0.2.10", nil} => 1.0,
             {"192.0.2.11", nil} => 0.0,
             {"192.0.2.12", nil} => 1.0
           }

    assert values(rows, "sweep.host.icmp_available") == %{
             {"192.0.2.10", nil} => 1.0,
             {"192.0.2.11", nil} => 0.0,
             {"192.0.2.12", nil} => 0.0
           }

    assert values(rows, "sweep.host.icmp_response_time_ns") == %{
             {"192.0.2.10", nil} => 1_500_000.0
           }

    assert values(rows, "sweep.host.icmp_packet_loss") == %{
             {"192.0.2.10", nil} => 0.0,
             {"192.0.2.11", nil} => 100.0
           }

    assert values(rows, "sweep.host.port.available") == %{
             {"192.0.2.10", "22"} => 0.0,
             {"192.0.2.10", "443"} => 1.0,
             {"192.0.2.11", "22"} => 0.0,
             {"192.0.2.11", "443"} => 0.0,
             {"192.0.2.12", "22"} => 1.0,
             {"192.0.2.12", "443"} => 0.0
           }

    assert values(rows, "sweep.host.port.response_time_ns") == %{
             {"192.0.2.10", "443"} => 2_000_000.0
           }

    [available] =
      Enum.filter(
        rows,
        &(&1.metric_name == "sweep.host.available" and &1.target_device_ip == "192.0.2.10")
      )

    # The identity and tags the unleased batch carries once core attests it, so both kinds
    # of sweep land in one per-agent series family.
    assert available.agent_id == @agent_id
    assert available.metric_type == "sweep"
    assert available.partition == "default"
    assert available.timestamp == DateTime.from_unix!(@observed_at + 10_000, :nanosecond)

    assert Map.take(available.tags, [
             "execution_id",
             "sweep_group_id",
             "target",
             "hostname",
             "metric_family",
             "source",
             "producer_kind",
             "producer_id",
             "payload_kind"
           ]) == %{
             "execution_id" => @execution_id,
             "sweep_group_id" => @group_id,
             "target" => "192.0.2.10",
             "hostname" => "host01.example.com",
             "metric_family" => "sweep",
             "source" => "sweep-metrics",
             "producer_kind" => "sweep",
             "producer_id" => @agent_id,
             "payload_kind" => "serviceradar.metric.v1"
           }
  end

  test "a large batch publishes bounded messages under stable per-message ids" do
    # 1 + 2 ports = 3 points per host without ICMP: 700 hosts are 2,100 points.
    hosts = for n <- 1..700, do: host(rem(n, 250) + 1, observed_at_delta_nano: n)
    parent = self()

    publish = fn subject, body, opts ->
      send(parent, {:published, subject, body, opts})
      :ok
    end

    assert :ok =
             SweepHostMetrics.publish(batch(hosts), identity(),
               in_transaction?: fn -> false end,
               publish: publish
             )

    messages =
      for _ <- 1..3 do
        assert_received {:published, subject, body, opts}
        {subject, MetricBatch.decode(body), opts[:msg_id]}
      end

    refute_received {:published, _, _, _}

    assert Enum.map(messages, &elem(&1, 2)) ==
             for(n <- 0..2, do: "#{@event_id}:sweep-host-metrics:#{n}")

    points =
      Enum.map(messages, fn {_, mb, _} ->
        mb.metrics |> Enum.map(&length(&1.points)) |> Enum.sum()
      end)

    assert points == [1_000, 1_000, 100]

    assert Enum.all?(messages, fn {subject, _, _} ->
             String.starts_with?(subject, "metrics.sweep.sweep.")
           end)

    assert Enum.all?(messages, fn {_, mb, _} -> mb.resource.agent_id == @agent_id end)
  end

  # The caller keeps its pending marker on an error, so a message that is neither stored nor
  # queued must surface as one, and the rest of the batch is left for the republish.
  test "a message that can be neither published nor queued is an error and stops the batch" do
    parent = self()
    hosts = for n <- 1..700, do: host(rem(n, 250) + 1, observed_at_delta_nano: n)

    assert {:error, {:publish_and_enqueue_failed, :oban_unavailable}} =
             SweepHostMetrics.publish(batch(hosts), identity(),
               in_transaction?: fn -> false end,
               publish: fn _subject, _body, opts ->
                 send(parent, {:attempted, opts[:msg_id]})
                 {:error, :timeout}
               end,
               enqueue: fn _job -> {:error, :oban_unavailable} end
             )

    assert_received {:attempted, "#{@event_id}:sweep-host-metrics:0"}
    refute_received {:attempted, _}
  end
end
