defmodule ServiceRadar.EventWriter.Processors.EdgeRecordEndpointInventoryDbTest do
  @moduledoc """
  End-to-end DB-backed integration tests for the `serviceradar.endpoint_inventory.scan`
  standing-grant contract through `ServiceRadar.EventWriter.Processors.EdgeRecord`.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXBOMV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXComponentV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1
  alias Serviceradar.Edge.V1.EndpointInventoryOSInfoV1
  alias Serviceradar.Edge.V1.EndpointInventoryPackageSetDeltaV1
  alias Serviceradar.Edge.V1.EndpointInventoryPackageV1
  alias Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1
  alias Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1
  alias Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryPackageSet
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots

  @moduletag :integration

  @endpoint_inventory_contract "serviceradar.endpoint_inventory.scan"
  @write_bytes_per_row 16_384

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:edge_record_endpoint_inventory_db_test)
    suffix = System.unique_integer([:positive])
    slug = "ei-edge-#{suffix}"
    agent_id = "agent-ei-edge-#{suffix}"
    device_id = "sr:#{Ecto.UUID.generate()}"
    artifact_hash_1 = String.pad_leading("a1#{suffix}", 64, "0")
    artifact_hash_2 = String.pad_leading("a2#{suffix}", 64, "0")
    now_usec = DateTime.truncate(DateTime.utc_now(), :microsecond)

    partition =
      Partition
      |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
      |> Ash.create!()

    ensure_agent!(agent_id, device_id, partition, actor)

    for hash <- [artifact_hash_1, artifact_hash_2] do
      Repo.insert_all(
        "endpoint_inventory_artifact_contents",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            artifact_hash: hash,
            object_key: "endpoint-inventory/artifacts/sha256/#{hash}.cdx.json",
            bucket: "serviceradar-endpoint-inventory",
            domain: "default",
            content_type: "application/vnd.cyclonedx+json",
            format: "CycloneDX",
            spec_version: "1.6",
            sha256: hash,
            size_bytes: 128,
            storage_backend: "datasvc_object_store",
            first_uploaded_at: now_usec,
            last_referenced_at: now_usec,
            reference_count: 1,
            metadata: %{},
            inserted_at: now_usec,
            updated_at: now_usec
          }
        ],
        prefix: "platform"
      )
    end

    {:ok,
     partition: partition,
     agent_id: agent_id,
     device_id: device_id,
     artifact_hash_1: artifact_hash_1,
     artifact_hash_2: artifact_hash_2,
     pkg_name_1: "synthetic-openssl-#{suffix}",
     pkg_name_2: "synthetic-curl-#{suffix}",
     key: IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))}
  end

  test "ingests a full endpoint inventory scan and a follow-up package delta scan",
       %{
         agent_id: agent_id,
         device_id: device_id,
         artifact_hash_1: artifact_hash_1,
         artifact_hash_2: artifact_hash_2,
         pkg_name_1: pkg_name_1,
         pkg_name_2: pkg_name_2
       } = ctx do
    norm_1 =
      EndpointInventoryPackageSet.normalize_delta_packages([
        %{
          "name" => pkg_name_1,
          "version" => "3.0.11",
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" => "pkg:deb/debian/#{pkg_name_1}@3.0.11?arch=amd64"
        }
      ])

    norm_2 =
      EndpointInventoryPackageSet.normalize_delta_packages([
        %{
          "name" => pkg_name_2,
          "version" => "8.5.0",
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" => "pkg:deb/debian/#{pkg_name_2}@8.5.0?arch=amd64"
        }
      ])

    hash_1 = EndpointInventoryPackageSet.server_package_set_hash(norm_1)
    hash_2 = EndpointInventoryPackageSet.server_package_set_hash(norm_1 ++ norm_2)

    scan_1 = %EndpointInventoryScanPayloadV1{
      schema_version: "serviceradar.endpoint_inventory.scan.v1",
      agent_id: agent_id,
      scan_id: "scan-full-#{agent_id}",
      collector_version: "1.2.3-synthetic",
      state: "scanned",
      coverage_state: "complete",
      config_hash: "cfg-hash-01",
      last_scan_at: "2026-07-14T12:00:00Z",
      last_successful_scan_at: "2026-07-14T12:00:00Z",
      os: %EndpointInventoryOSInfoV1{
        name: "SyntheticLinux",
        id: "synthetic",
        version: "12",
        version_id: "12",
        pretty_name: "SyntheticLinux 12"
      },
      enabled_plugins: ["os/dpkg"],
      detected_plugins: ["os/dpkg"],
      diagnostics: [
        %EndpointInventorySourceSummaryV1{
          name: "os/dpkg",
          type: "os",
          state: "scanned",
          has_detected: true,
          detected: true,
          package_count: 1,
          duration_ms: 35
        }
      ],
      package_count: 1,
      package_set_hash: hash_1,
      artifact_hash: artifact_hash_1,
      hash_algorithm: "sha256-v1",
      upload_reason: "changed",
      duration_ms: 35,
      standing_question_result_counts: [
        %EndpointInventoryStandingQuestionResultCountV1{
          question_id: "q-openssl",
          matched: true,
          count: 1
        }
      ],
      sbom: %EndpointInventoryCycloneDXBOMV1{
        bom_format: "CycloneDX",
        spec_version: "1.6",
        version: 1,
        components: [
          %EndpointInventoryCycloneDXComponentV1{
            type: "library",
            name: pkg_name_1,
            version: "3.0.11",
            purl: "pkg:deb/debian/#{pkg_name_1}@3.0.11?arch=amd64",
            properties: [
              %EndpointInventoryCycloneDXPropertyV1{
                name: "serviceradar:package_manager",
                value: "dpkg"
              },
              %EndpointInventoryCycloneDXPropertyV1{
                name: "serviceradar:architecture",
                value: "amd64"
              }
            ]
          }
        ]
      },
      metadata_json: Jason.encode!(%{"reason" => "initial_scan", "producer_id" => "scalibr"})
    }

    frame_1 = build_frame(ctx, scan_1)

    assert {:ok, :inserted} =
             EdgeRecord.ingest(frame_1.record_bytes, frame_1.headers, Repo, request: stored_ack())

    current_1 =
      Repo.one!(
        from(s in "endpoint_inventory_scans",
          where: s.agent_id == ^agent_id and s.current == true,
          select: %{
            scan_id: s.scan_id,
            device_uid: s.device_uid,
            state: s.state,
            coverage_state: s.coverage_state,
            package_count: s.package_count,
            package_set_hash: s.package_set_hash
          }
        ),
        prefix: "platform"
      )

    assert current_1.scan_id == "scan-full-#{agent_id}"
    assert current_1.device_uid == device_id
    assert current_1.state == "scanned"
    assert current_1.coverage_state == "complete"
    assert current_1.package_count == 1
    assert current_1.package_set_hash == hash_1

    packages_1 =
      Repo.all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^agent_id and p.current == true,
          order_by: [asc: p.name],
          select: p.name
        ),
        prefix: "platform"
      )

    assert packages_1 == [pkg_name_1]

    # Ingest a follow-up delta scan adding pkg_name_2 on top of the current package set.
    scan_2 = %EndpointInventoryScanPayloadV1{
      schema_version: "serviceradar.endpoint_inventory.scan.v1",
      agent_id: agent_id,
      scan_id: "scan-delta-#{agent_id}",
      collector_version: "1.2.3-synthetic",
      state: "scanned",
      coverage_state: "complete",
      config_hash: "cfg-hash-01",
      last_scan_at: "2026-07-14T12:01:00Z",
      last_successful_scan_at: "2026-07-14T12:01:00Z",
      enabled_plugins: ["os/dpkg"],
      detected_plugins: ["os/dpkg"],
      diagnostics: [
        %EndpointInventorySourceSummaryV1{
          name: "os/dpkg",
          type: "os",
          state: "scanned",
          has_detected: true,
          detected: true,
          package_count: 2,
          duration_ms: 20
        }
      ],
      package_count: 2,
      package_set_hash: hash_2,
      artifact_hash: artifact_hash_2,
      hash_algorithm: "sha256-v1",
      upload_reason: "changed",
      duration_ms: 20,
      package_delta: %EndpointInventoryPackageSetDeltaV1{
        schema: "serviceradar.endpoint_inventory.package_delta.v1",
        base_package_set_hash: hash_1,
        target_package_set_hash: hash_2,
        hash_algorithm: "sha256-v1",
        added: [
          %EndpointInventoryPackageV1{
            name: pkg_name_2,
            version: "8.5.0",
            architecture: "amd64",
            manager: "dpkg",
            purl: "pkg:deb/debian/#{pkg_name_2}@8.5.0?arch=amd64"
          }
        ]
      },
      metadata_json: Jason.encode!(%{"reason" => "delta_scan", "producer_id" => "scalibr"})
    }

    frame_2 = build_frame(ctx, scan_2)

    assert {:ok, :inserted} =
             EdgeRecord.ingest(frame_2.record_bytes, frame_2.headers, Repo, request: stored_ack())

    packages_2 =
      Repo.all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^agent_id and p.current == true,
          order_by: [asc: p.name],
          select: p.name
        ),
        prefix: "platform"
      )

    assert packages_2 == Enum.sort([pkg_name_1, pkg_name_2])
  end

  defp build_frame(ctx, %EndpointInventoryScanPayloadV1{} = scan) do
    {:ok, grant} =
      OutputGrants.reconcile(ctx.agent_id, @endpoint_inventory_contract, ctx.partition.id)

    payload = EndpointInventoryScanPayloadV1.encode(scan)
    now = DateTime.utc_now()

    contract = %{
      contract_id: @endpoint_inventory_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "endpoint-inventory-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 1,
      max_projected_write_bytes: @write_bytes_per_row
    }

    production = OutputGrants.production_capability(grant, contract, ctx.key, now)
    {:production, claims} = production.claims

    unsealed = %EdgeRecordV1{
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
        origin_principal_id: ctx.agent_id,
        producer_instance_id: ctx.agent_id,
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
      network_scope_id: Ecto.UUID.dump!(ctx.partition.id),
      projected_row_count: 1,
      projected_write_bytes: 2_048,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: unsealed.network_scope_id,
      authenticated_agent_id: ctx.agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record = %{unsealed | semantic_envelope_sha256: SemanticDigest.compute(unsealed)}
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

    %{record: record, record_bytes: record_bytes, headers: headers}
  end

  defp stored_ack do
    test = self()

    fn subject, body, request_opts ->
      send(test, {:metrics_published, subject, body, request_opts})
      {:ok, %{body: ~s({"stream":"metrics","seq":1})}}
    end
  end

  defp ensure_agent!(agent_id, device_id, partition, actor) do
    if !Repo.get(Agent, agent_id) do
      device =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_id,
            ip: "198.51.100.50",
            partition: partition.slug,
            hostname: "endpoint-01.example.com"
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
end
