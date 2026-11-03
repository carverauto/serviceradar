defmodule ServiceRadar.EventWriter.Processors.EdgeRecordDiscoveryDbTest do
  @moduledoc """
  Real-Postgres coverage for the discovery edge-record projectors (mapper
  devices/interfaces/topology, netprobe discovery, sync pages): a fresh
  record reaches the same destination the legacy result route reached, a
  replay is a no-op, a revoked grant is refused before anything ingests,
  and sync pages keep the run shape (chunk numbering, final-only
  population, control marker) the DIRE pipeline keys on.

  Serial and sandbox-owned: the discovery projectors schedule sync
  ingestion, so these tests run it inline (`sync_ingestor_async: false`,
  restored on exit) exactly as the result-router suites do.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MapperDeviceBatchV1
  alias Serviceradar.Edge.V1.MapperDeviceRecordV1
  alias Serviceradar.Edge.V1.MapperInterfaceBatchV1
  alias Serviceradar.Edge.V1.MapperInterfaceRecordV1
  alias Serviceradar.Edge.V1.NetprobeDiscoveryBatchV1
  alias Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1
  alias Serviceradar.Edge.V1.SyncControlMarkerV1
  alias Serviceradar.Edge.V1.SyncDeviceRecordV1
  alias Serviceradar.Edge.V1.SyncMetaV1
  alias Serviceradar.Edge.V1.SyncPageBatchV1
  alias Serviceradar.Edge.V1.SyncPopulationReportV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots

  require Ecto.Query

  @mapper_devices_contract "serviceradar.mapper.devices.batch"
  @mapper_interfaces_contract "serviceradar.mapper.interfaces.batch"
  @netprobe_contract "serviceradar.netprobe.discovery.batch"
  @sync_page_contract "serviceradar.sync.page.batch"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)

    on_exit(fn ->
      if is_nil(previous_async) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_async)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor_async, previous_async)
      end
    end)

    :ok
  end

  describe "mapper device batch records" do
    test "a fresh batch creates the device through sync ingestion and a replay adds nothing" do
      frame =
        discovery_frame(@mapper_devices_contract, mapper_device_batch("192.0.2.10"), 1,
          bytes_per_row: 16_384
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 1
      assert [%{hostname: "sw-core-01.example.com"}] = devices_by_ip(frame, "192.0.2.10")

      assert {:ok, :replay} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 1
      assert [%{hostname: "sw-core-01.example.com"}] = devices_by_ip(frame, "192.0.2.10")
    end

    test "a record whose grant was revoked is refused and ingests nothing" do
      frame =
        discovery_frame(@mapper_devices_contract, mapper_device_batch("192.0.2.12"), 1,
          bytes_per_row: 16_384
        )

      assert {:ok, _grant} =
               OutputGrants.reconcile(
                 frame.agent_id,
                 @mapper_devices_contract,
                 frame.partition_id,
                 false
               )

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
      assert [] = devices_by_ip(frame, "192.0.2.12")
    end

    test "a device without an identity anchor is refused at decode" do
      batch = %MapperDeviceBatchV1{
        agent_id: "agent-x",
        devices: [%MapperDeviceRecordV1{hostname: "anchorless.example.com"}]
      }

      frame = discovery_frame(@mapper_devices_contract, batch, 1, bytes_per_row: 16_384)

      assert {:error, :mapper_device_no_anchor} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
    end
  end

  describe "mapper interface batch records" do
    test "interfaces attach to the device the device batch created" do
      device_frame =
        discovery_frame(@mapper_devices_contract, mapper_device_batch("192.0.2.20"), 1,
          bytes_per_row: 16_384
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(device_frame.record_bytes, device_frame.headers, Repo,
                 request: stored_ack()
               )

      interface_batch = %MapperInterfaceBatchV1{
        agent_id: device_frame.agent_id,
        partition: device_frame.partition_slug,
        interfaces: [
          %MapperInterfaceRecordV1{
            device_id: mapper_device_id("192.0.2.20"),
            device_ip: "192.0.2.20",
            if_index: 3,
            if_name: "xe-0/0/0",
            if_descr: "uplink to core",
            if_speed: 10_000_000_000,
            if_phys_address: "00:53:00:00:00:13",
            ip_addresses: ["192.0.2.20"],
            source: "snmp",
            timestamp_unix_nano: ago_nano(30),
            agent_id: device_frame.agent_id,
            partition: device_frame.partition_slug
          }
        ]
      }

      frame =
        discovery_frame(@mapper_interfaces_contract, interface_batch, 1,
          bytes_per_row: 8_192,
          agent_id: device_frame.agent_id,
          partition: device_frame.partition
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      [%{uid: _device_uid}] = devices_by_ip(frame, "192.0.2.20")

      interfaces =
        Repo.all(
          Ecto.Query.from(i in Interface,
            where: i.device_ip == "192.0.2.20",
            select: map(i, [:if_name])
          )
        )

      assert [%{if_name: "xe-0/0/0"}] = interfaces
    end
  end

  describe "netprobe discovery batch records" do
    test "a fresh batch enriches the device another producer established, metadata intact" do
      # passive-netprobe is enrichment-only (SourcePolicy): a fingerprint
      # never mints a device. Establish the host through the mapper first,
      # as a census/mapper sighting does in production.
      device_frame =
        discovery_frame(@mapper_devices_contract, mapper_device_batch("192.0.2.44"), 1,
          bytes_per_row: 16_384
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(device_frame.record_bytes, device_frame.headers, Repo,
                 request: stored_ack()
               )

      batch = %NetprobeDiscoveryBatchV1{
        records: [
          %NetprobeDiscoveryRecordV1{
            ip: "192.0.2.44",
            partition: "default",
            source: "passive-netprobe",
            discovery_source: "passive-netprobe",
            timestamp_unix_nano: ago_nano(30),
            metadata: %{
              "discovery_source" => "passive-netprobe",
              "passive_fingerprint.os_family" => "SyntheticOS"
            }
          }
        ]
      }

      frame =
        discovery_frame(@netprobe_contract, batch, 1,
          bytes_per_row: 8_192,
          agent_id: device_frame.agent_id,
          partition: device_frame.partition
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert [%{metadata: metadata}] = devices_by_ip(frame, "192.0.2.44")
      assert metadata["passive_fingerprint.os_family"] == "SyntheticOS"
    end
  end

  describe "sync page batch records" do
    test "pages create devices in run order and the control page closes the run" do
      {agent_id, partition, source_id} = sync_source!()

      first =
        discovery_frame(
          @sync_page_contract,
          sync_page(source_id, ["src-a"], chunk_index: 0),
          1,
          bytes_per_row: 16_384,
          agent_id: agent_id,
          partition: partition
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(first.record_bytes, first.headers, Repo, request: stored_ack())

      final_batch =
        sync_page(source_id, ["src-b", "src-c"],
          chunk_index: 1,
          total_chunks: 2,
          is_final: true,
          population: true
        )

      final =
        discovery_frame(@sync_page_contract, final_batch, 2,
          bytes_per_row: 16_384,
          agent_id: first.agent_id,
          partition: first.partition
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(final.record_bytes, final.headers, Repo, request: stored_ack())

      control_batch = %SyncPageBatchV1{
        sync_meta: %SyncMetaV1{
          sync_service_id: source_id,
          sync_run_id: "run-synthetic-empty",
          chunk_index: 0,
          total_chunks: 1,
          is_final: true,
          population: %SyncPopulationReportV1{raw_rows: 0}
        },
        control_marker: %SyncControlMarkerV1{
          control_type: "collection_final",
          timestamp_unix_nano: ago_nano(5)
        }
      }

      control =
        discovery_frame(@sync_page_contract, control_batch, 1,
          bytes_per_row: 16_384,
          agent_id: first.agent_id,
          partition: first.partition
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(control.record_bytes, control.headers, Repo,
                 request: stored_ack()
               )

      ips = first |> partition_devices() |> Enum.map(& &1.ip) |> Enum.sort()
      assert ips == ["192.0.2.60", "192.0.2.61", "192.0.2.62"]
    end

    test "a page without a sync run id is refused at decode" do
      batch = %SyncPageBatchV1{
        sync_meta: %SyncMetaV1{sync_service_id: "svc-synthetic-1"},
        devices: [%SyncDeviceRecordV1{uid: "src-x", ip: "192.0.2.99"}]
      }

      frame = discovery_frame(@sync_page_contract, batch, 1, bytes_per_row: 16_384)

      assert {:error, :sync_page_no_run_id} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp ago_nano(seconds) do
    DateTime.utc_now() |> DateTime.shift(second: -seconds) |> DateTime.to_unix(:nanosecond)
  end

  defp mapper_device_id(ip) do
    "sr:00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(:erlang.phash2(ip) + 1), 12, "0")}"
  end

  defp mapper_device_batch(ip) do
    %MapperDeviceBatchV1{
      devices: [
        %MapperDeviceRecordV1{
          device_id: mapper_device_id(ip),
          ip: ip,
          source: "mapper",
          is_available: true,
          hostname: "sw-core-01.example.com",
          mac: "00:53:00:00:00:10",
          timestamp_unix_nano: ago_nano(30),
          metadata: %{
            "source" => "mapper",
            "identity_mac_kind" => "primary",
            "sys_name" => "sw-core-01.example.com"
          }
        }
      ]
    }
  end

  defp sync_source! do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: agent_id, name: agent_id},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    source =
      ServiceRadar.Integrations.IntegrationSource
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:credentials, %{
        secret_key: "synthetic-sync-secret",
        page_size: "997"
      })
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-sync-#{System.unique_integer([:positive])}",
          source_type: :armis,
          endpoint: "https://sync.example.com",
          agent_id: agent_id,
          northbound_enabled: true,
          custom_fields: ["availability"],
          settings: %{"batch_size" => 137},
          page_size: 997
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {agent_id, partition, to_string(source.id)}
  end

  defp sync_page(source_id, uids, opts) do
    devices =
      Enum.with_index(uids, fn uid, idx ->
        %SyncDeviceRecordV1{
          uid: uid,
          ip: "192.0.2.#{60 + chunk_offset(opts) + idx}",
          source: "armis",
          hostname: "host-#{uid}.example.com",
          timestamp_unix_nano: ago_nano(30),
          metadata: %{
            "source_device_id" => uid,
            "armis_device_id" => uid,
            "integration_id" => uid,
            "integration_type" => "armis",
            "sync_service_id" => source_id
          }
        }
      end)

    meta = %SyncMetaV1{
      sync_service_id: source_id,
      sync_run_id: "run-synthetic-1",
      chunk_index: Keyword.get(opts, :chunk_index, 0),
      total_chunks: Keyword.get(opts, :total_chunks, 0),
      total_devices: 3,
      is_final: Keyword.get(opts, :is_final, false)
    }

    meta =
      if Keyword.get(opts, :population, false) do
        %{
          meta
          | population: %SyncPopulationReportV1{
              raw_rows: 3,
              valid_occurrences: 3,
              distinct_source_ids: 3
            }
        }
      else
        meta
      end

    %SyncPageBatchV1{sync_meta: meta, devices: devices}
  end

  defp chunk_offset(opts), do: Keyword.get(opts, :chunk_index, 0)

  defp devices_by_ip(frame, ip) do
    frame
    |> partition_devices()
    |> Enum.filter(&(&1.ip == ip))
  end

  defp partition_devices(frame) do
    partition = frame.partition_slug

    Repo.all(
      Ecto.Query.from(d in Device,
        where: d.partition == ^partition and d.ip != "198.51.100.254",
        select: map(d, [:uid, :ip, :hostname, :metadata])
      )
    )
  end

  defp discovery_frame(contract_id, batch, rows, opts) do
    partition =
      Keyword.get_lazy(opts, :partition, fn ->
        partition!(random_uuid(4), SystemActor.system(:edge_record_test))
      end)

    agent_id = Keyword.get(opts, :agent_id, "agent-#{System.unique_integer([:positive])}")

    if !Keyword.has_key?(opts, :agent_id) do
      ensure_agent!(agent_id, partition, SystemActor.system(:edge_record_test))
    end

    {:ok, grant} = OutputGrants.reconcile(agent_id, contract_id, partition.id, true)

    batch = stamp_batch_agent(batch, agent_id, partition.slug)
    payload = encode_batch(batch)
    now = DateTime.utc_now()

    contract = %{
      contract_id: contract_id,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "discovery-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 163_840_000
    }

    key = IssuerKey.from_seed(:binary.copy(<<0x5B>>, 32))
    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    record = %EdgeRecordV1{
      event_id: Ecto.UUID.dump!(ExecutionSlots.mint_id(now)),
      output_contract:
        struct(
          EdgeOutputContractRef,
          Map.take(claims, [
            :contract_id,
            :contract_version,
            :contract_bundle_sha256,
            :registry_epoch,
            :registry_snapshot_sha256,
            :effective_grant_sha256
          ])
        ),
      production_capability: production,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      producer_context: %EdgeProducerContext{
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: agent_id,
        producer_instance_id: agent_id,
        producer_assignment_id: claims.producer_assignment_id,
        authority_epoch: claims.authority_epoch,
        run_id: claims.run_id,
        run_shard: 0,
        scope_id: claims.scope_id,
        scope_sha256: claims.scope_sha256,
        package_id: claims.package_id,
        package_sha256: claims.package_sha256
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: rows,
      projected_write_bytes: rows * Keyword.fetch!(opts, :bytes_per_row),
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot)
    |> Map.merge(%{
      agent_id: agent_id,
      partition_id: partition.id,
      partition: partition,
      partition_slug: partition.slug
    })
  end

  defp stamp_batch_agent(%MapperDeviceBatchV1{} = batch, agent_id, partition) do
    devices =
      Enum.map(batch.devices, fn device ->
        %{device | agent_id: agent_id, gateway_id: agent_id, partition: partition}
      end)

    %{batch | agent_id: agent_id, gateway_id: agent_id, partition: partition, devices: devices}
  end

  defp stamp_batch_agent(%MapperInterfaceBatchV1{} = batch, agent_id, partition) do
    %{batch | agent_id: agent_id, gateway_id: agent_id, partition: partition}
  end

  defp stamp_batch_agent(%NetprobeDiscoveryBatchV1{} = batch, agent_id, partition) do
    records =
      Enum.map(batch.records, fn record ->
        %{record | agent_id: agent_id, partition: partition}
      end)

    %{batch | records: records}
  end

  defp stamp_batch_agent(%SyncPageBatchV1{} = batch, agent_id, partition) do
    devices =
      Enum.map(batch.devices || [], fn device ->
        %{device | agent_id: agent_id, gateway_id: "gw-test", partition: partition}
      end)

    %{batch | devices: devices}
  end

  defp encode_batch(%MapperDeviceBatchV1{} = batch), do: MapperDeviceBatchV1.encode(batch)
  defp encode_batch(%MapperInterfaceBatchV1{} = batch), do: MapperInterfaceBatchV1.encode(batch)

  defp encode_batch(%NetprobeDiscoveryBatchV1{} = batch),
    do: NetprobeDiscoveryBatchV1.encode(batch)

  defp encode_batch(%SyncPageBatchV1{} = batch), do: SyncPageBatchV1.encode(batch)

  defp encode_frame(record, batch, slot) do
    record = %{record | projected_write_bytes: record.projected_row_count * 2_048}
    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, record.semantic_envelope_sha256, record_sha256)

    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    {:ok, provenance} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: PublicationIdentity.mode_fresh(),
        delivery_proof: nil,
        record_sha256: record_sha256,
        route_map_version: 1
      })

    headers = %{
      "Nats-Msg-Id" => nats_msg_id,
      "Sr-Edge-Delivery-Id" => delivery_id,
      "Sr-Edge-Transport-Provenance" => provenance
    }

    %{record_bytes: record_bytes, headers: headers, record: record, batch: batch, slot: slot}
  end

  defp stored_ack do
    test = self()

    fn subject, body, request_opts ->
      send(test, {:metrics_published, subject, body, request_opts})
      {:ok, %{body: ~s({"stream":"metrics","seq":1})}}
    end
  end

  defp partition!(bytes, actor) do
    case Repo.get(Partition, Ecto.UUID.cast!(bytes)) do
      nil ->
        slug = "edge-#{System.unique_integer([:positive])}"

        Partition
        |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
        |> Ash.create!()

      partition ->
        partition
    end
  end

  defp ensure_agent!(agent_id, partition, actor) do
    if !Repo.get(Agent, agent_id) do
      device =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-#{agent_id}",
            ip: "198.51.100.254",
            partition: partition.slug,
            hostname: agent_id
          },
          actor: actor
        )
        |> Ash.create!()

      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id, device_uid: device.uid},
        actor: actor
      )
      |> Ash.create!()
    end
  end

  defp random_uuid(version) do
    <<b0::binary-6, v::8, b1::8, var::8, b2::binary-7>> = :crypto.strong_rand_bytes(16)
    new_v = Bitwise.bor(Bitwise.bsl(version, 4), Bitwise.band(v, 0x0F))
    new_var = Bitwise.bor(0x80, Bitwise.band(var, 0x3F))
    <<b0::binary, new_v::8, b1::8, new_var::8, b2::binary>>
  end

  defp ledger_count(record) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    count
  end
end
