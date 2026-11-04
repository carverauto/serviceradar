defmodule ServiceRadar.EventWriter.Processors.EdgeRecordBumblebeeDbTest do
  @moduledoc """
  Database-backed coverage for the Bumblebee endpoint scan edge-record projector
  (`serviceradar.bumblebee.scan` v1).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.Projectors.BumblebeeScan
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.BumblebeeFindingV1
  alias Serviceradar.Edge.V1.BumblebeeScanPayloadV1
  alias Serviceradar.Edge.V1.BumblebeeSkippedRootV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceRiskContribution
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots

  require Ash.Query

  @bumblebee_contract "serviceradar.bumblebee.scan"
  @bytes_per_row 16_384

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "projects a Bumblebee scan with findings, preserves risk_score 0, ignores spoofed device_uid, and replays idempotently" do
    actor = SystemActor.system(:edge_record_bumblebee_db_test)
    suffix = System.unique_integer([:positive])
    agent_id = "agent-bumblebee-#{suffix}"
    host_device_uid = "sr:bumblebee-host-#{suffix}"
    spoofed_device_uid = "sr:bumblebee-spoofed-#{suffix}"

    partition = partition!(random_uuid(4), actor)
    create_device!(actor, host_device_uid)
    create_device!(actor, spoofed_device_uid)
    create_agent!(actor, agent_id, host_device_uid)

    scan = %BumblebeeScanPayloadV1{
      schema_version: "serviceradar.bumblebee.scan.v1",
      agent_id: agent_id,
      device_uid: spoofed_device_uid,
      run_id: "run-#{suffix}-1",
      scanner_version: "0.2.0",
      catalog_snapshot_ref: "2026.04.14.1",
      state: "scanned",
      coverage_state: "partial",
      attempted_root_count: 2,
      scanned_root_count: 1,
      skipped_root_count: 1,
      root_covered: true,
      attempted_roots: ["/", "/mnt/nfs"],
      scanned_roots: ["/"],
      skipped_roots: [
        %BumblebeeSkippedRootV1{path: "/mnt/nfs", reason: "remote_fs"}
      ],
      last_scan_at: "2026-04-14T22:00:00Z",
      last_successful_scan_at: "2026-04-14T22:00:00Z",
      metadata_json: ~s({"profile":"default"}),
      findings: [
        %BumblebeeFindingV1{
          finding_id: "finding-#{suffix}-1",
          catalog_id: "CVE-2026-0001",
          severity: "low",
          risk_score: 0,
          has_risk_score: true,
          ecosystem: "cargo",
          package_name: "demo",
          package_version: "1.2.3",
          evidence_json: ~s({"lockfile":"/app/Cargo.lock"}),
          confidence: "high",
          metadata_json: ~s({"scanner":"bumblebee"})
        },
        %BumblebeeFindingV1{
          finding_id: "finding-#{suffix}-2",
          catalog_id: "CVE-2026-0002",
          severity: "high",
          has_risk_score: false,
          ecosystem: "deb",
          package_name: "openssl",
          package_version: "3.0.0"
        }
      ]
    }

    frame = standing_grant_frame(agent_id, partition, scan, 2)
    assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

    assert {:ok, posture} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert posture.device_uid == host_device_uid
    assert posture.run_id == "run-#{suffix}-1"
    assert posture.active_finding_count == 2
    assert posture.skipped_roots == [%{"path" => "/mnt/nfs", "reason" => "remote_fs"}]
    assert posture.metadata["profile"] == "default"

    assert {:ok, []} =
             BumblebeeDevicePosture
             |> Ash.Query.for_read(:by_device, %{device_uid: spoofed_device_uid}, actor: actor)
             |> Ash.read(actor: actor)

    assert {:ok, active_findings} =
             BumblebeeFinding.list_active_by_device(host_device_uid, actor: actor)

    findings_by_id = Map.new(active_findings, &{&1.finding_id, &1})
    assert map_size(findings_by_id) == 2
    assert findings_by_id["finding-#{suffix}-1"].risk_score == 0
    assert findings_by_id["finding-#{suffix}-1"].evidence == %{"lockfile" => "/app/Cargo.lock"}
    assert findings_by_id["finding-#{suffix}-1"].metadata == %{"scanner" => "bumblebee"}
    assert findings_by_id["finding-#{suffix}-2"].risk_score == 80

    assert {:ok, [contribution]} =
             DeviceRiskContribution.list_active_by_device(host_device_uid, actor: actor)

    assert contribution.source == "bumblebee"

    assert {:ok, :replay} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)
    assert ledger_count(frame.record) == 1

    # A follow-up completed zero-finding scan with projected_row_count 1 resolves prior findings.
    empty_scan = %BumblebeeScanPayloadV1{
      schema_version: "serviceradar.bumblebee.scan.v1",
      agent_id: agent_id,
      run_id: "run-#{suffix}-2",
      scanner_version: "0.2.0",
      catalog_snapshot_ref: "2026.04.14.1",
      state: "scanned",
      coverage_state: "complete",
      attempted_root_count: 1,
      scanned_root_count: 1,
      root_covered: true,
      attempted_roots: ["/"],
      scanned_roots: ["/"],
      last_scan_at: "2026-04-14T23:00:00Z",
      last_successful_scan_at: "2026-04-14T23:00:00Z",
      findings: []
    }

    empty_frame = standing_grant_frame(agent_id, partition, empty_scan, 1)

    assert {:ok, :inserted} =
             EdgeRecord.ingest(empty_frame.record_bytes, empty_frame.headers, Repo)

    assert {:ok, updated_posture} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert updated_posture.run_id == "run-#{suffix}-2"
    assert updated_posture.active_finding_count == 0

    assert {:ok, []} = BumblebeeFinding.list_active_by_device(host_device_uid, actor: actor)
  end

  test "refuses a Bumblebee scan record when its standing grant is revoked" do
    actor = SystemActor.system(:edge_record_bumblebee_db_test)
    suffix = System.unique_integer([:positive])
    agent_id = "agent-bumblebee-revoked-#{suffix}"
    host_device_uid = "sr:bumblebee-revoked-host-#{suffix}"

    partition = partition!(random_uuid(4), actor)
    create_device!(actor, host_device_uid)
    create_agent!(actor, agent_id, host_device_uid)

    scan = %BumblebeeScanPayloadV1{
      schema_version: "serviceradar.bumblebee.scan.v1",
      agent_id: agent_id,
      run_id: "run-revoked-#{suffix}",
      state: "scanned",
      coverage_state: "complete"
    }

    frame = standing_grant_frame(agent_id, partition, scan, 1)

    assert {:ok, 1} = OutputGrants.revoke_agent(agent_id)

    assert {:error, :output_grant_not_current} =
             EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

    assert ledger_count(frame.record) == 0

    assert {:ok, nil} =
             BumblebeeDevicePosture.get_by_agent(agent_id,
               actor: actor,
               not_found_error?: false
             )
  end

  test "decode/1 refuses invalid Bumblebee scan payloads and source authorization" do
    valid_scan = %BumblebeeScanPayloadV1{
      schema_version: "serviceradar.bumblebee.scan.v1",
      agent_id: "agent-1",
      run_id: "run-1",
      findings: [%BumblebeeFindingV1{finding_id: "f-1"}]
    }

    assert {:ok, ^valid_scan} = BumblebeeScan.decode(raw_record(valid_scan, 1))

    assert {:error, :bumblebee_scan_no_agent_id} =
             BumblebeeScan.decode(raw_record(%{valid_scan | agent_id: " "}, 1))

    assert {:error, :bumblebee_scan_no_run_id} =
             BumblebeeScan.decode(raw_record(%{valid_scan | run_id: ""}, 1))

    assert {:error, :bumblebee_scan_row_count} =
             BumblebeeScan.decode(raw_record(valid_scan, 2))

    assert {:error, :bumblebee_scan_invalid_metadata_json} =
             BumblebeeScan.decode(raw_record(%{valid_scan | metadata_json: "[]"}, 1))

    assert {:error, :bumblebee_finding_no_id} =
             BumblebeeScan.decode(
               raw_record(%{valid_scan | findings: [%BumblebeeFindingV1{catalog_id: "CVE-1"}]}, 1)
             )

    assert {:error, :bumblebee_finding_invalid_evidence_json} =
             BumblebeeScan.decode(
               raw_record(
                 %{
                   valid_scan
                   | findings: [%BumblebeeFindingV1{finding_id: "f-1", evidence_json: "null"}]
                 },
                 1
               )
             )

    assert {:error, :bumblebee_scan_source_authorization} =
             BumblebeeScan.decode(%{
               raw_record(valid_scan, 1)
               | source_authorization: %EdgeSourceAuthorizationV1{}
             })
  end

  defp raw_record(scan, rows) do
    body = BumblebeeScanPayloadV1.encode(scan)

    %EdgeRecordV1{
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      payload: body,
      encoded_size: byte_size(body),
      uncompressed_size: byte_size(body),
      payload_sha256: :crypto.hash(:sha256, body),
      projected_row_count: rows
    }
  end

  defp standing_grant_frame(agent_id, partition, scan, rows) do
    {:ok, grant} = OutputGrants.reconcile(agent_id, @bumblebee_contract, partition.id)
    payload = BumblebeeScanPayloadV1.encode(scan)
    now = DateTime.utc_now()

    contract = %{
      contract_id: @bumblebee_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "bumblebee-bundle"),
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
      projected_write_bytes: rows * @bytes_per_row,
      cost_model_version: 1,
      payload: payload
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

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

  defp partition!(bytes, actor) do
    case Repo.get(Partition, Ecto.UUID.cast!(bytes)) do
      nil ->
        slug = "edge-bumblebee-#{System.unique_integer([:positive])}"

        Partition
        |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
        |> Ash.create!()

      partition ->
        partition
    end
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{uid}.example.com",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_agent!(actor, agent_id, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_id,
        name: agent_id,
        type_id: 0,
        device_uid: device_uid,
        capabilities: ["bumblebee"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp ledger_count(record) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    count
  end

  defp random_uuid(version) do
    <<b0::binary-6, v::8, b1::8, var::8, b2::binary-7>> = :crypto.strong_rand_bytes(16)
    new_v = Bitwise.bor(Bitwise.bsl(version, 4), Bitwise.band(v, 0x0F))
    new_var = Bitwise.bor(0x80, Bitwise.band(var, 0x3F))
    <<b0::binary, new_v::8, b1::8, new_var::8, b2::binary>>
  end
end
