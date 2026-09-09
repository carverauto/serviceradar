defmodule ServiceRadar.Integrations.ArmisDireE2ETest do
  @moduledoc """
  Closed-loop Armis/DIRE regression coverage.

  The shell harness starts a local faker and runs the real Go Armis driver to
  produce the JSONL input consumed here. This test then uses the same Core
  ResultsRouter, sweep ingestor, and Oban worker paths used in production.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag :armis_dire_e2e

  # This suite needs a faker endpoint and a fixture file that only
  # scripts/test-armis-dire-e2e.sh provides; no workflow sets them for the plain
  # `mix test --include integration` run. It previously tried to opt out by returning
  # {:skip, reason} from setup_all, which ExUnit does not accept -- setup must return :ok, a
  # keyword list, or a map -- so it raised RuntimeError and failed both tests on every CI run.
  #
  # Excluding the :armis_dire_e2e tag would not help either: ExUnit runs a test matching an
  # `include` filter even when it also matches an `exclude` one, and this module is tagged
  # :integration, so --include integration re-includes it whatever else is excluded. A
  # compile-time `@moduletag skip:` is the one gate include/exclude cannot override.
  #
  # Three states, so a deleted secret can never masquerade as "no fixture" (same form as
  # ServiceRadar.Scans.AdhocScanNatsE2ETest):
  #   none configured      -> SKIP (local dev, untrusted fork, ordinary CI run)
  #   PARTIALLY configured -> FAIL in setup_all, naming what is missing
  #   fully configured     -> RUN
  @armis_vars ["ARMIS_E2E_FAKER_URL", "ARMIS_E2E_FIXTURE_FILE"]
  @armis_present Enum.filter(@armis_vars, &(System.get_env(&1) not in [nil, ""]))
  @armis_missing @armis_vars -- @armis_present
  @armis_configured @armis_missing == []
  @armis_partial @armis_present != [] and @armis_missing != []

  @moduletag skip: not @armis_configured and not @armis_partial

  @tag timeout: 1_800_000

  setup_all do
    previous_log_level = Logger.level()
    Logger.configure(level: :warning)

    on_exit(fn -> Logger.configure(level: previous_log_level) end)
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)

    previous_concurrency =
      Application.get_env(:serviceradar_core, :sync_ingestor_batch_concurrency)

    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)
    Application.put_env(:serviceradar_core, :sync_ingestor_batch_concurrency, 1)
    Application.put_env(:serviceradar_core, :results_router_batching, false)

    on_exit(fn ->
      restore_env(:sync_ingestor_async, previous_async)
      restore_env(:results_router_batching, previous_batching)
      restore_env(:sync_ingestor_batch_concurrency, previous_concurrency)
    end)

    case {System.get_env("ARMIS_E2E_FAKER_URL"), System.get_env("ARMIS_E2E_FIXTURE_FILE")} do
      {endpoint, fixture}
      when is_binary(endpoint) and endpoint != "" and is_binary(fixture) and fixture != "" ->
        actor = SystemActor.system(:armis_dire_e2e)
        agent = create_connected_agent!(actor)
        source = create_source!(actor, endpoint, agent.uid)

        {:ok, actor: actor, agent: agent, endpoint: endpoint, fixture: fixture, source: source}

      _ ->
        # Unreachable when nothing is configured -- @moduletag skip: above handles that. This
        # is the PARTIAL case, and it must be loud: a renamed or deleted secret should not be
        # able to quietly disable this coverage. Raising (rather than returning {:skip, ...},
        # which ExUnit rejects from a setup callback) names exactly what is missing.
        raise """
        #{inspect(__MODULE__)} is partially configured: #{Enum.join(@armis_missing, ", ")} \
        #{if length(@armis_missing) == 1, do: "is", else: "are"} missing.

        Set all of #{Enum.join(@armis_vars, " and ")}, or none of them. This suite is driven by
        scripts/test-armis-dire-e2e.sh, which sets both:

            ./scripts/test-armis-dire-e2e.sh --profile fast
        """
    end
  end

  test "preserves typed Armis identity through churn, sweep availability, and northbound", %{
    actor: actor,
    endpoint: endpoint,
    fixture: fixture,
    source: source
  } do
    pages = fixture_pages!(fixture)
    expected_devices = pages |> Enum.filter(&(&1["run"] == 0)) |> page_update_count()
    latest_run = pages |> Enum.map(& &1["run"]) |> Enum.max()

    assert expected_devices > 0
    assert Enum.sum(Enum.map(pages, & &1["count"])) >= expected_devices

    pages = Enum.map(pages, &rebind_page(&1, source.id))
    initial_pages = Enum.filter(pages, &(&1["run"] == 0))

    ingest_sync_pages!(initial_pages)

    initial_typed_devices = typed_device_map!()

    actual_device_count =
      scalar!("SELECT COUNT(*) FROM platform.ocsf_devices WHERE deleted_at IS NULL")

    if actual_device_count != expected_devices do
      actual_id_set =
        MapSet.new(
          Repo.query!("""
          SELECT identifier_value
          FROM platform.device_identifiers
          WHERE identifier_type = 'armis_device_id'
          """).rows,
          fn [value] -> value end
        )

      expected_id_set = expected_id_set(expected_devices)

      IO.puts(
        "Armis/DIRE cardinality diagnostic: " <>
          "devices=#{actual_device_count}/#{expected_devices} " <>
          "typed_ids=#{MapSet.size(actual_id_set)}/#{MapSet.size(expected_id_set)} " <>
          "missing=#{expected_id_set |> MapSet.difference(actual_id_set) |> MapSet.to_list() |> inspect()} " <>
          "extra=#{actual_id_set |> MapSet.difference(expected_id_set) |> MapSet.to_list() |> inspect()}"
      )
    end

    assert actual_device_count == expected_devices

    latest_pages = Enum.filter(pages, &(&1["run"] == latest_run))

    if latest_run != 0 do
      ingest_sync_pages!(latest_pages)
      assert typed_device_map!() == initial_typed_devices
    end

    assert scalar!(
             "SELECT COUNT(*) FROM platform.device_identifiers WHERE identifier_type = 'armis_device_id'"
           ) ==
             expected_devices

    # Driver-scoped Armis identity flows through the generic integration_id
    # contract: one scoped row per device, never a bare numeric value.
    assert scalar!("""
           SELECT COUNT(*)
           FROM platform.device_identifiers
           WHERE identifier_type = 'integration_id'
             AND COALESCE(metadata->>'integration_type', '') = 'armis'
           """) == expected_devices

    assert scalar!("""
           SELECT COUNT(*)
           FROM platform.device_identifiers
           WHERE identifier_type = 'integration_id'
             AND COALESCE(metadata->>'integration_type', '') = 'armis'
             AND identifier_value LIKE 'armis:%'
           """) == expected_devices

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)
    assert length(candidates) == expected_devices
    assert MapSet.new(candidates, & &1.armis_device_id) == expected_id_set(expected_devices)

    sweep_group = create_sweep_group!(actor)

    latest_updates = Enum.flat_map(latest_pages, & &1["updates"])

    ingest_sweep!({sweep_group, latest_updates})

    assert scalar!(
             "SELECT COUNT(*) FROM platform.ocsf_devices WHERE deleted_at IS NULL AND is_available = true"
           ) ==
             expected_devices

    Req.delete!(endpoint <> "/debug/armis/northbound/updates")

    job = %Oban.Job{
      id: 4_707_001,
      args: %{"integration_source_id" => source.id, "manual" => true}
    }

    assert :ok = ArmisNorthboundRunWorker.perform(job)

    capture = Req.get!(endpoint <> "/debug/armis/northbound/updates").body
    assert capture["success"]
    assert capture["data"]["total"] == expected_devices
    assert capture["data"]["updated"] == expected_devices
    assert capture["data"]["missing"] == 0

    captured_ids = MapSet.new(capture["data"]["results"], & &1["device_id"])

    assert captured_ids == expected_id_set(expected_devices)

    assert {:ok, finished_source} = IntegrationSource.get_by_id(source.id, actor: actor)
    assert finished_source.northbound_status == :success
    assert finished_source.northbound_last_device_count == expected_devices
    assert finished_source.northbound_last_updated_count == expected_devices
    assert finished_source.northbound_last_skipped_count == 0

    assert {:ok, run} = IntegrationUpdateRun.get_by_oban_job_id(4_707_001, actor: actor)
    assert run.status == :success
    assert run.device_count == expected_devices
    assert run.updated_count == expected_devices
    assert run.skipped_count == 0
    assert run.error_count == 0

    identity_conflicts = Map.get(run.metadata, "identity_conflicts", %{})
    categories = Map.get(identity_conflicts, "categories", %{})

    assert Map.keys(categories) -- ["active_ip_conflict"] == []

    write_debug_artifact!("clean-run.json", %{
      "source_id" => source.id,
      "device_count" => run.device_count,
      "updated_count" => run.updated_count,
      "skipped_count" => run.skipped_count,
      "error_count" => run.error_count,
      "status" => to_string(run.status),
      "identity_conflicts" => identity_conflicts
    })
  end

  test "scopes identical IDs and withholds only ambiguous conflict categories", %{
    actor: actor,
    endpoint: endpoint,
    source: source
  } do
    source_b = create_source!(actor, endpoint, source.agent_id)

    ingest_sync_update!(actor, source.id, "192.0.2.101", "91001", true)
    ingest_sync_update!(actor, source.id, "192.0.2.102", "91002", true)
    ingest_sync_update!(actor, source.id, "192.0.2.103", "91004", true)
    ingest_sync_update!(actor, source.id, "192.0.2.104", "91005", true)
    ingest_sync_update!(actor, source.id, "192.0.2.105", "91006", true)
    ingest_sync_update!(actor, source_b.id, "192.0.2.201", "91001", true)

    {:ok, stale_device_page} = Device.get_by_ip("192.0.2.102", false, actor: actor)
    stale_device = single_result(stale_device_page)

    update_device_metadata!(actor, stale_device, %{
      "armis_device_id" => "stale-91002",
      "integration_id" => "stale-91002",
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    generic_only =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "armis-generic-only",
        ip: "192.0.2.108",
        is_available: true,
        discovery_sources: ["armis"],
        metadata: %{
          "integration_type" => "armis",
          "integration_id" => "91003",
          "sync_service_id" => source.id
        }
      })

    register_identifier!(actor, generic_only.uid, :integration_id, "91003", %{
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    split_generic =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "armis-split-generic",
        ip: "192.0.2.106",
        is_available: false,
        discovery_sources: ["armis"],
        metadata: %{
          "integration_type" => "armis",
          "integration_id" => "91004",
          "sync_service_id" => source.id
        }
      })

    register_identifier!(actor, split_generic.uid, :integration_id, "91004", %{
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    duplicate_device =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "armis-duplicate-typed",
        ip: "192.0.2.107",
        is_available: true,
        discovery_sources: ["armis"],
        metadata: %{
          "integration_type" => "armis",
          "armis_device_id" => "91005",
          "sync_service_id" => source.id
        }
      })

    Repo.query!("DROP INDEX platform.device_identifiers_unique_identifier_index")

    register_identifier!(
      actor,
      duplicate_device.uid,
      :armis_device_id,
      "91005",
      %{
        "integration_type" => "armis",
        "sync_service_id" => source.id
      },
      "default:armis:#{source.id}"
    )

    {:ok, multiple_id_device_page} = Device.get_by_ip("192.0.2.105", false, actor: actor)
    multiple_id_device = single_result(multiple_id_device_page)

    register_identifier!(
      actor,
      multiple_id_device.uid,
      :armis_device_id,
      "91006-other",
      %{
        "integration_type" => "armis",
        "sync_service_id" => source.id
      },
      "default:armis:#{source.id}"
    )

    assert %{audited_count: audited_count} = SourceIdentityDrift.audit_and_persist()
    assert audited_count >= 5

    report = SourceIdentityDrift.source_conflict_report(source)
    assert report["categories"]["metadata_identifier_disagreement"] >= 1
    assert report["categories"]["split_typed_generic_identifier"] >= 1
    assert report["categories"]["multiple_typed_ids_per_device"] >= 1
    assert report["categories"]["typed_id_on_multiple_devices"] >= 1
    assert report["skipped_count"] >= 3

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)

    assert MapSet.new(candidates, & &1.armis_device_id) ==
             MapSet.new(["91001", "91005"])

    assert {:ok, source_b_candidates} = ArmisNorthboundRunner.load_candidates(source_b)
    assert MapSet.new(source_b_candidates, & &1.armis_device_id) == MapSet.new(["91001"])

    repair =
      SourceIdentityDrift.repair_armis(apply: true, source_id: source.id, actor: "armis-e2e")

    assert repair.summary["applied_repair_count"] >= 1

    assert {:ok, repaired_candidates} = ArmisNorthboundRunner.load_candidates(source)
    assert Enum.any?(repaired_candidates, &(&1.armis_device_id == "91002"))
    refute Enum.any?(repaired_candidates, &(&1.armis_device_id == "91004"))
    refute Enum.any?(repaired_candidates, &(&1.armis_device_id == "91006"))

    assert {:ok, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               execute_batches: fn _source, candidates, _opts ->
                 {:ok,
                  %{
                    device_count: length(candidates),
                    updated_count: length(candidates),
                    skipped_count: 0,
                    error_count: 0,
                    batch_count: 1,
                    errors: []
                  }}
               end
             )

    assert result.updated_count ==
             repaired_candidates
             |> ArmisNorthboundRunner.collapse_candidates()
             |> length()

    assert result.error_count == 0
    assert result.skipped_count >= 2
    assert result.device_count == result.updated_count + result.skipped_count

    write_debug_artifact!("identity-conflict-matrix.json", %{
      "source_id" => source.id,
      "audit" => report,
      "repair" => repair.summary,
      "candidate_count_after_repair" => length(repaired_candidates),
      "updated_count" => result.updated_count,
      "skipped_count" => result.skipped_count,
      "error_count" => result.error_count
    })
  end

  defp create_source!(actor, endpoint, agent_id) do
    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{
      secret_key: "armis-e2e-secret",
      page_size: "997"
    })
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "armis-dire-e2e-#{System.unique_integer([:positive])}",
        source_type: :armis,
        endpoint: endpoint,
        agent_id: agent_id,
        northbound_enabled: true,
        custom_fields: ["availability"],
        settings: %{"batch_size" => 137},
        page_size: 997
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.load!([:credentials_encrypted, :credentials], actor: actor)
  end

  defp create_connected_agent!(actor) do
    uid = "armis-e2e-agent"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp ingest_sync_update!(actor, source_id, ip, armis_id, is_available) do
    update = %{
      "ip" => ip,
      "mac" => unique_mac!(armis_id),
      "hostname" => "armis-#{armis_id}",
      "source" => "armis",
      "is_available" => is_available,
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{"sync_service_id" => source_id}
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
  end

  defp create_device!(actor, attrs) do
    Device
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp register_identifier!(actor, device_uid, type, value, metadata, partition \\ "default") do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: type,
        identifier_value: value,
        partition: partition,
        confidence: :strong,
        metadata: metadata
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp update_device_metadata!(actor, device, metadata) do
    device
    |> Ash.Changeset.for_update(:update, %{metadata: metadata}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp unique_mac!(seed) do
    seed
    |> :erlang.phash2(16_777_215)
    |> Integer.to_string(16)
    |> String.pad_leading(6, "0")
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&("02:" <> &1))
  end

  defp single_result([result]), do: result
  defp single_result(result), do: result

  defp fixture_pages!(path) do
    path
    |> File.stream!(:line, [])
    |> Stream.reject(&(String.trim(&1) == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp page_update_count(pages), do: Enum.sum(Enum.map(pages, & &1["count"]))

  defp rebind_page(page, source_id) do
    updates =
      Enum.map(page["updates"], fn update ->
        sync_meta = Map.put(update["sync_meta"], "sync_service_id", source_id)
        Map.put(update, "sync_meta", sync_meta)
      end)

    Map.put(page, "updates", updates)
  end

  defp ingest_sync_pages!(pages) do
    Enum.each(pages, fn page ->
      sync_meta = page["updates"] |> List.first() |> Map.fetch!("sync_meta")

      status = %{
        source: "results",
        service_type: "sync",
        agent_id: "armis-e2e-agent",
        gateway_id: "armis-e2e-gateway",
        partition: "default",
        message: Jason.encode!(page["updates"]),
        chunk_index: sync_meta["chunk_index"],
        total_chunks: sync_meta["total_chunks"],
        is_final: sync_meta["is_final"]
      }

      assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    end)
  end

  defp create_sweep_group!(actor) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "armis-dire-e2e-sweep-#{System.unique_integer([:positive])}",
        partition: "default",
        agent_id: "armis-e2e-agent",
        enabled: false,
        static_targets: [],
        ports: [443],
        sweep_modes: ["icmp", "tcp"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp ingest_sweep!({sweep_group, updates}) do
    execution_id = Ash.UUID.generate()
    hosts = Enum.map(updates, &sweep_host/1)
    chunk_size = 500
    chunks = Enum.chunk_every(hosts, chunk_size)
    total_chunks = max(length(chunks), 1)
    last_sweep = DateTime.to_iso8601(DateTime.utc_now())

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, chunk_index} ->
      payload = %{
        "execution_id" => execution_id,
        "sweep_group_id" => sweep_group.id,
        "last_sweep" => last_sweep,
        "total_hosts" => length(hosts),
        "hosts" => chunk
      }

      status = %{
        source: "results",
        service_type: "sweep",
        agent_id: "armis-e2e-agent",
        gateway_id: "armis-e2e-gateway",
        partition: "default",
        chunk_index: chunk_index,
        total_chunks: total_chunks,
        is_final: chunk_index == total_chunks - 1,
        message: Jason.encode!(payload)
      }

      assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    end)
  end

  defp sweep_host(update) do
    %{
      "host" => update["ip"],
      "hostname" => update["hostname"],
      "icmp_status" => %{
        "available" => true,
        "round_trip" => "1ms",
        "packet_loss" => 0
      },
      "port_results" => [
        %{"port" => 443, "available" => true, "response_time" => "2ms"}
      ]
    }
  end

  defp expected_id_set(count), do: MapSet.new(1..count, &to_string/1)

  defp scalar!(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp typed_device_map! do
    Map.new(
      Repo.query!("""
      SELECT identifier_value, device_id
      FROM platform.device_identifiers
      WHERE identifier_type = 'armis_device_id'
      """).rows,
      fn [identifier, device_id] -> {identifier, device_id} end
    )
  end

  defp write_debug_artifact!(name, payload) do
    case System.get_env("ARMIS_E2E_ARTIFACT_DIR") do
      dir when is_binary(dir) and dir != "" ->
        path = Path.join(dir, name)

        case File.write(path, Jason.encode!(payload, pretty: true)) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.warn("failed to write Armis/DIRE artifact #{path}: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
