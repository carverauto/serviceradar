defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Plugins.ConfigSchema

  @moduletag :requires_app

  # A fake SRQL runner that returns hour-of-week profile rows shaped exactly as the
  # `stats:profile_hour_of_week` SQL emits them (string keys, device_id AS series),
  # branching on the source's metric_type so cpu and memory get distinct profiles.
  defmodule ProfileRunner do
    @moduledoc false
    @device "default:192.168.1.50"

    def query(query, _opts) do
      cond do
        String.contains?(query, "sysmon.cpu") -> {:ok, rows(35.0, 70.0)}
        String.contains?(query, "sysmon.memory") -> {:ok, rows(55.0, 88.0)}
        true -> {:ok, []}
      end
    end

    # Complete profile: a low normal hour and a HIGH recurring peak hour (Mon 09:00).
    defp rows(normal_center, peak_center) do
      for dow <- 0..6, hod <- 0..23 do
        center = if dow == 1 and hod == 9, do: peak_center, else: normal_center
        row(dow, hod, center)
      end
    end

    defp row(dow, hod, center) do
      %{
        "series" => @device,
        "dow" => dow,
        "hod" => hod,
        "sample_value" => center,
        "bucket" => "2026-06-22T#{pad(hod)}:00:00Z",
        "bucket_count" => 8,
        "center" => center,
        "mad" => 2.0
      }
    end

    defp pad(n) when n < 10, do: "0#{n}"
    defp pad(n), do: "#{n}"

    def device, do: @device
  end

  defp sources do
    # Default sources include delivery-only interface sources; ProfileRunner returns rows
    # only for cpu/memory, so these tests keep covering the host baseline contract.
    Source.defaults()
  end

  test "build keys each baseline by <device_uid>|<metric_name> with no cpu/memory collision" do
    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: sources(), runner: ProfileRunner)

    device = ProfileRunner.device()
    cpu_key = "#{device}|cpu.usage_percent"
    mem_key = "#{device}|memory.used_percent"

    assert baselines |> Map.keys() |> Enum.sort() == Enum.sort([cpu_key, mem_key])

    # The peak Monday-09:00 bucket carries the robust median center for each metric.
    assert %{"buckets" => cpu_buckets} = baselines[cpu_key]
    peak = Enum.find(cpu_buckets, &(&1["dow"] == 1 and &1["hod"] == 9))
    assert peak["center"] == 70.0
    # MAD 2.0 * 1.4826 MAD->sigma consistency constant.
    assert_in_delta peak["scale"], 2.9652, 1.0e-6
    assert peak["sample_count"] == 8

    assert %{"buckets" => mem_buckets} = baselines[mem_key]
    assert Enum.find(mem_buckets, &(&1["dow"] == 1 and &1["hod"] == 9))["center"] == 88.0
  end

  defmodule InterfaceProfileRunner do
    @moduledoc false
    @device "sr:router-1"

    def query(query, _opts) do
      if String.contains?(query, "ifInOctets") do
        {:ok, profile_rows(7, 125.0) ++ profile_rows(8, 250.0)}
      else
        {:ok, []}
      end
    end

    defp profile_rows(if_index, center) do
      for dow <- 0..6, hod <- 0..23, do: row(dow, hod, if_index, center)
    end

    defp row(dow, hod, if_index, center) do
      %{
        "series" => @device,
        "partition" => "edge-a",
        "target_device_ip" => "192.0.2.10",
        "if_index" => if_index,
        "metric_name" => "ifInOctets",
        "dow" => dow,
        "hod" => hod,
        "sample_value" => center,
        "bucket" => "2026-06-22T09:00:00Z",
        "bucket_count" => 8,
        "center" => center,
        "mad" => 5.0
      }
    end

    def device, do: @device
  end

  test "build keys interface baselines by edge target identity and if_index" do
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: [source], runner: InterfaceProfileRunner)

    if7_key = "192.0.2.10|ifInOctets|7"
    if8_key = "192.0.2.10|ifInOctets|8"

    assert baselines |> Map.keys() |> Enum.sort() == Enum.sort([if7_key, if8_key])

    assert %{"encoding" => "compact_168_f32", "centers" => if7_centers, "scales" => if7_scales} =
             baselines[if7_key]

    assert Enum.at(if7_centers, 1 * 24 + 9) == 125.0
    assert Enum.at(if7_scales, 1 * 24 + 9) == 7.413

    assert %{"encoding" => "compact_168_f32", "centers" => if8_centers} = baselines[if8_key]
    assert Enum.at(if8_centers, 1 * 24 + 9) == 250.0

    assert :ok =
             ConfigSchema.validate_params(load_addon_schema(), %{
               "seasonal_baselines" => baselines
             })
  end

  defmodule GovernedInterfaceRunner do
    @moduledoc false

    def query(query, _opts) do
      if String.contains?(query, "ifInOctets") do
        rows = [
          profile_rows("partition-a", "sr:router-1", 1, 100.0, 8),
          profile_rows("partition-a", "sr:router-1", 2, 50.0, 8),
          profile_rows("partition-a", "sr:router-1", 3, 10.0, 8),
          profile_rows("partition-a", "sr:router-1", 4, 200.0, 2),
          profile_rows("partition-b", "sr:router-2", 7, 80.0, 8)
        ]

        {:ok, List.flatten(rows)}
      else
        {:ok, []}
      end
    end

    defp profile_rows(partition, device, if_index, center, count) do
      for slot <- 0..100 do
        row(partition, device, if_index, center, count, div(slot, 24), rem(slot, 24))
      end
    end

    defp row(partition, device, if_index, center, count, dow, hod) do
      %{
        "series" => device,
        "partition" => partition,
        "target_device_ip" => "192.0.2.#{if_index}",
        "if_index" => if_index,
        "metric_name" => "ifInOctets",
        "dow" => dow,
        "hod" => hod,
        "sample_value" => center,
        "bucket" => "2026-06-22T09:00:00Z",
        "bucket_count" => count,
        "center" => center,
        "mad" => 5.0
      }
    end
  end

  test "build_scoped gates interface baselines by history, top-K, per-agent cap, and telemetry" do
    test_pid = self()
    handler_id = "edge-baseline-producer-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:serviceradar, :seasonal_disposition, :edge_baseline, :delivery],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    assert {:ok, delivery} =
             EdgeBaselineProducer.build_scoped(
               sources: [source],
               runner: GovernedInterfaceRunner,
               interface_top_k_per_device: 2,
               max_baselines_per_agent: 1
             )

    assert delivery.scoped_baselines |> Map.keys() |> Enum.sort() == [
             "partition-a",
             "partition-b"
           ]

    assert Map.keys(delivery.scoped_baselines["partition-a"]) == ["192.0.2.1|ifInOctets|1"]
    assert Map.keys(delivery.scoped_baselines["partition-b"]) == ["192.0.2.7|ifInOctets|7"]
    assert delivery.stats.scoped_series == 2
    assert delivery.stats.topk_dropped == 1
    assert delivery.stats.cap_dropped == 1
    assert delivery.stats.quality_dropped == 1

    assert_receive {:telemetry, [:serviceradar, :seasonal_disposition, :edge_baseline, :delivery],
                    measurements, %{result: :ok}}

    assert measurements.cap_dropped == 1
    assert measurements.scoped_series == 2
  end

  test "reconcile writes interface baselines only to matching assignment params" do
    test_pid = self()
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    profiles = [
      %{id: Ecto.UUID.generate(), params: %{"metric_feed" => %{"sources" => ["sysmon", "snmp"]}}}
    ]

    assignments = [
      %{agent_uid: "agent-a", params: %{"metric_feed" => %{"sources" => ["snmp"]}}},
      %{agent_uid: "agent-z", params: %{"metric_feed" => %{"sources" => ["snmp"]}}}
    ]

    profile_updater = fn profile, params, _actor ->
      send(test_pid, {:profile_updated, params})
      {:ok, Map.put(profile, :params, params)}
    end

    assignment_updater = fn assignment, params, _actor ->
      send(test_pid, {:assignment_updated, assignment.agent_uid, params})
      {:ok, Map.put(assignment, :params, params)}
    end

    assert {:ok, summary} =
             EdgeBaselineProducer.reconcile(
               sources: [source],
               runner: GovernedInterfaceRunner,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: profile_updater,
               assignments_loader: fn _profiles, _actor -> {:ok, assignments} end,
               assignment_updater: assignment_updater,
               polling_agents_resolver: fn device_uid, _agent_uids, _actor ->
                 if device_uid == "sr:router-1", do: ["agent-a"], else: []
               end,
               heartbeat_recorder: fn _metadata -> :ok end
             )

    assert summary.global_series == 0
    assert summary.scoped_agents == 1
    assert summary.assignments_updated == 2

    assert_received {:profile_updated, %{"seasonal_baselines" => %{}}}

    assert_received {:assignment_updated, "agent-a", agent_a_params}
    assert agent_a_params["metric_feed"] == %{"sources" => ["snmp"]}
    refute Map.has_key?(agent_a_params["seasonal"] || %{}, "min_bucket_samples")
    assert Map.has_key?(agent_a_params["seasonal_baselines"], "192.0.2.1|ifInOctets|1")
    assert Map.has_key?(agent_a_params["seasonal_baselines"], "192.0.2.2|ifInOctets|2")
    assert Map.has_key?(agent_a_params["seasonal_baselines"], "192.0.2.3|ifInOctets|3")
    refute Map.has_key?(agent_a_params["seasonal_baselines"], "192.0.2.4|ifInOctets|4")

    assert_received {:assignment_updated, "agent-z", agent_z_params}
    assert agent_z_params["seasonal_baselines"] == %{}
  end

  defmodule DuplicateIpInterfaceRunner do
    @moduledoc false

    def query(query, _opts) do
      if String.contains?(query, "ifInOctets") do
        {:ok,
         rows("sr:site-a-router", "site-a", 125.0) ++
           rows("sr:site-b-router", "site-b", 250.0)}
      else
        {:ok, []}
      end
    end

    defp rows(device, partition, center) do
      for slot <- 0..100 do
        %{
          "series" => device,
          "partition" => partition,
          "target_device_ip" => "10.0.0.10",
          "if_index" => 7,
          "metric_name" => "ifInOctets",
          "dow" => div(slot, 24),
          "hod" => rem(slot, 24),
          "sample_value" => center,
          "bucket" => "2026-06-22T09:00:00Z",
          "bucket_count" => 8,
          "center" => center,
          "mad" => 5.0
        }
      end
    end
  end

  test "does not blend same private interface IPs from separate sites" do
    test_pid = self()
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))
    profiles = [%{id: Ecto.UUID.generate(), params: %{}}]

    assignments = [
      %{agent_uid: "agent-site-a", params: %{}},
      %{agent_uid: "agent-site-b", params: %{}}
    ]

    assert {:ok, %{scoped_series: 2}} =
             EdgeBaselineProducer.reconcile(
               sources: [source],
               runner: DuplicateIpInterfaceRunner,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               assignments_loader: fn _profiles, _actor -> {:ok, assignments} end,
               polling_agents_resolver: fn
                 "sr:site-a-router", _agents, _actor -> ["agent-site-a"]
                 "sr:site-b-router", _agents, _actor -> ["agent-site-b"]
               end,
               profile_updater: fn profile, params, _actor ->
                 {:ok, %{profile | params: params}}
               end,
               assignment_updater: fn assignment, params, _actor ->
                 send(test_pid, {:assignment_params, assignment.agent_uid, params})
                 {:ok, assignment}
               end,
               heartbeat_recorder: fn _metadata -> :ok end
             )

    assert_receive {:assignment_params, "agent-site-a", site_a}
    assert_receive {:assignment_params, "agent-site-b", site_b}

    key = "10.0.0.10|ifInOctets|7"
    assert Enum.at(site_a["seasonal_baselines"][key]["centers"], 0) == 125.0
    assert Enum.at(site_b["seasonal_baselines"][key]["centers"], 0) == 250.0
  end

  test "the built payload validates against the add-on config schema" do
    {:ok, baselines} = EdgeBaselineProducer.build(sources: sources(), runner: ProfileRunner)

    schema = load_addon_schema()
    assert :ok = ConfigSchema.validate_params(schema, %{"seasonal_baselines" => baselines})
  end

  test "reconcile writes seasonal_baselines into profile params, preserving other writers" do
    test_pid = self()

    profiles = [
      %{
        id: "profile-1",
        params: %{
          "managed" => %{"n_sigma" => 4.0},
          "metric_feed" => %{"sources" => ["sysmon", "snmp"]}
        }
      }
    ]

    updater = fn profile, params, _actor ->
      send(test_pid, {:updated, profile.id, params})
      {:ok, Map.put(profile, :params, params)}
    end

    assert {:ok, summary} =
             EdgeBaselineProducer.reconcile(
               sources: sources(),
               runner: ProfileRunner,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: updater,
               heartbeat_recorder: fn _metadata -> :ok end
             )

    assert summary.profiles_updated == 1
    assert summary.series == 2

    assert_received {:updated, "profile-1", params}
    # Config projection is a disjoint writer under params["managed"].
    assert params["managed"] == %{"n_sigma" => 4.0}
    # Existing feed ownership is preserved.
    assert params["metric_feed"] == %{"sources" => ["sysmon", "snmp"]}
    # The delivered baseline is keyed by the canonical device-uid|metric.
    device = ProfileRunner.device()
    assert Map.has_key?(params["seasonal_baselines"], "#{device}|memory.used_percent")
    assert Map.has_key?(params["seasonal_baselines"], "#{device}|cpu.usage_percent")
  end

  test "reconcile records a per-run producer heartbeat and stamps no meta key" do
    test_pid = self()
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    profiles = [%{id: Ecto.UUID.generate(), params: %{}}]
    assignments = [%{agent_uid: "agent-a", params: %{}}]

    assert {:ok, summary} =
             EdgeBaselineProducer.reconcile(
               sources: [source],
               runner: GovernedInterfaceRunner,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: fn profile, params, _actor ->
                 send(test_pid, {:profile_updated, params})
                 {:ok, Map.put(profile, :params, params)}
               end,
               assignments_loader: fn _profiles, _actor -> {:ok, assignments} end,
               assignment_updater: fn assignment, params, _actor ->
                 send(test_pid, {:assignment_updated, params})
                 {:ok, Map.put(assignment, :params, params)}
               end,
               polling_agents_resolver: fn _device_uid, _agent_uids, _actor -> ["agent-a"] end,
               heartbeat_recorder: fn metadata ->
                 send(test_pid, {:heartbeat, metadata})
                 :ok
               end
             )

    # The freshness tripwire keys off this heartbeat, so a successful run must
    # record exactly one with the delivery summary as metadata.
    assert_received {:heartbeat, metadata}
    refute_received {:heartbeat, _duplicate}

    assert metadata == %{
             profiles: summary.profiles_total,
             assignments: summary.assignments_total,
             profiles_updated: summary.profiles_updated,
             assignments_updated: summary.assignments_updated,
             series: summary.series
           }

    assert_received {:profile_updated, profile_params}
    assert_received {:assignment_updated, assignment_params}

    # No `seasonal_baselines_meta` sibling key: the DB-stored (previously
    # approved) package schema has root `additionalProperties: false`, so an
    # undeclared key would fail params validation on every existing deployment
    # and break baseline delivery entirely.
    refute Map.has_key?(profile_params, "seasonal_baselines_meta")
    refute Map.has_key?(assignment_params, "seasonal_baselines_meta")
    assert :ok = ConfigSchema.validate_params(load_addon_schema(), assignment_params)
  end

  test "reconcile heartbeat failures never fail a successful delivery" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _summary} =
                 EdgeBaselineProducer.reconcile(
                   sources: sources(),
                   runner: ProfileRunner,
                   profiles_loader: fn _actor -> {:ok, [%{id: "profile-1", params: %{}}]} end,
                   profile_updater: fn profile, params, _actor ->
                     {:ok, Map.put(profile, :params, params)}
                   end,
                   heartbeat_recorder: fn _metadata -> raise "health surface down" end
                 )
      end)

    assert log =~ "Failed to record seasonal edge baseline heartbeat"
  end

  test "reconcile skips params writes when the delivered payload is unchanged" do
    test_pid = self()
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    run = fn profiles, assignments, tag ->
      EdgeBaselineProducer.reconcile(
        sources: [source],
        runner: GovernedInterfaceRunner,
        profiles_loader: fn _actor -> {:ok, profiles} end,
        profile_updater: fn profile, params, _actor ->
          send(test_pid, {tag, :profile_updated, params})
          {:ok, Map.put(profile, :params, params)}
        end,
        assignments_loader: fn _profiles, _actor -> {:ok, assignments} end,
        assignment_updater: fn assignment, params, _actor ->
          send(test_pid, {tag, :assignment_updated, params})
          {:ok, Map.put(assignment, :params, params)}
        end,
        polling_agents_resolver: fn _device_uid, _agent_uids, _actor -> ["agent-a"] end,
        heartbeat_recorder: fn _metadata ->
          send(test_pid, {tag, :heartbeat})
          :ok
        end
      )
    end

    profile_id = Ecto.UUID.generate()

    assert {:ok, first} =
             run.(
               [%{id: profile_id, params: %{}}],
               [%{agent_uid: "agent-a", params: %{}}],
               :first
             )

    assert first.profiles_updated == 1
    assert first.assignments_updated == 1
    assert_received {:first, :profile_updated, profile_params}
    assert_received {:first, :assignment_updated, assignment_params}
    assert_received {:first, :heartbeat}

    # Re-running against params that already carry the identical payload must
    # not write (no hourly no-op churn, no agent config redelivery) — but the
    # run is still successful, so the heartbeat still fires.
    assert {:ok, second} =
             run.(
               [%{id: profile_id, params: profile_params}],
               [%{agent_uid: "agent-a", params: assignment_params}],
               :second
             )

    assert second.profiles_updated == 0
    assert second.assignments_updated == 0
    assert second.profiles_total == 1
    assert second.assignments_total == 1
    refute_received {:second, :profile_updated, _params}
    refute_received {:second, :assignment_updated, _params}
    assert_received {:second, :heartbeat}
  end

  defmodule EmptyRunner do
    @moduledoc false
    def query(_query, _opts), do: {:ok, []}
  end

  test "build returns an empty payload when no profile rows exist (rolling-only)" do
    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: sources(), runner: EmptyRunner)

    assert baselines == %{}
  end

  defp load_addon_schema do
    path =
      Path.expand("../../../../../../addons/anomaly-addon/config.schema.json", __DIR__)

    path
    |> File.read!()
    |> Jason.decode!()
  end
end
