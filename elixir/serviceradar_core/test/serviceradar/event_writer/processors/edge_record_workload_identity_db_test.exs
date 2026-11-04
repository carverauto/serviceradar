defmodule ServiceRadar.EventWriter.Processors.EdgeRecordWorkloadIdentityDbTest do
  @moduledoc """
  End-to-end projection of `serviceradar.workload_identity.snapshot` edge
  records through `ServiceRadar.EventWriter.Processors.EdgeRecord` into
  `platform.workload_identity_current` via
  `ServiceRadar.WorkloadIdentity.persist_snapshot/1`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.Projectors.WorkloadIdentity, as: WorkloadIdentityProjector
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1
  alias Serviceradar.Edge.V1.WorkloadIdentityRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotEndpointV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots

  @workload_identity_contract "serviceradar.workload_identity.snapshot"
  @write_bytes_per_row 8_192

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:edge_record_workload_identity_db_test)
    slug = "wi-edge-#{System.unique_integer([:positive])}"
    agent_id = "agent-wi-edge-#{System.unique_integer([:positive])}"

    partition =
      Partition
      |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
      |> Ash.create!()

    ensure_agent!(agent_id, partition, actor)

    on_exit(fn ->
      if :ets.whereis(:workload_identity_skip_guard) != :undefined do
        :ets.delete(:workload_identity_skip_guard, {slug, agent_id})
      end
    end)

    {:ok,
     actor: actor,
     partition: partition,
     agent_id: agent_id,
     key: IssuerKey.from_seed(:binary.copy(<<0x59>>, 32))}
  end

  test "standing grant catalog includes workload identity snapshot contract" do
    assert {@workload_identity_contract, 1} in ContractCatalog.standing_grant_refs()
    assert {:ok, entry} = ContractCatalog.fetch({@workload_identity_contract, 1})
    assert entry.projector == WorkloadIdentityProjector
    assert entry.authority == :standing_grant
    assert entry.max_projected_rows == 10_000
    assert entry.write_bytes_per_row == @write_bytes_per_row
    assert entry.package_id == "serviceradar.agent.workload_identity"
  end

  test "ingests a populated WorkloadIdentitySnapshotV1 record and deduplicates replay", ctx do
    snap = %WorkloadIdentitySnapshotV1{
      observed_at_unix_nano: 1_780_000_000_000_000_000,
      enabled: true,
      endpoint: %WorkloadIdentitySnapshotEndpointV1{
        type: "Cri",
        path: "/run/containerd/containerd.sock",
        source: "CommonPath"
      },
      count: 2,
      context_name: "example-ctx",
      cluster_id: "cluster-123",
      cluster_name: "example-cluster",
      identities: [
        %WorkloadIdentityContainerLookupV1{
          container_id: "container-alpha",
          identity: %WorkloadIdentityRecordV1{
            pod_sandbox_id: "sandbox-alpha",
            pod_name: "checkout-api-6d8d9b7f44-k9znm",
            pod_namespace: "payments",
            pod_uid: "pod-uid-alpha",
            container_id: "container-alpha",
            container_name: "checkout-api",
            image: "registry.example.com/checkout-api:1.2.3",
            image_ref: "registry.example.com/checkout-api@sha256:1111",
            runtime_pid: 4312,
            has_runtime_pid: true,
            cgroup_path: "/kubepods.slice/cri-containerd-alpha.scope",
            labels: %{"app.kubernetes.io/name" => "checkout-api"},
            annotations: %{"io.kubernetes.container.restartCount" => "0"},
            runtime_source: "Containerd",
            confidence: "High"
          }
        },
        %WorkloadIdentityContainerLookupV1{
          container_id: "container-beta",
          identity: %WorkloadIdentityRecordV1{
            pod_sandbox_id: "sandbox-beta",
            pod_name: "worker-79f58f48c7-lw2kq",
            pod_namespace: "jobs",
            pod_uid: "pod-uid-beta",
            container_id: "container-beta",
            container_name: "worker",
            image: "registry.example.com/worker:0.9.0",
            image_ref: "registry.example.com/worker@sha256:2222",
            has_runtime_pid: false,
            labels: %{"app.kubernetes.io/name" => "worker"},
            runtime_source: "Containerd",
            confidence: "Medium",
            degradation_reason: "runtime pid missing"
          }
        }
      ]
    }

    frame = build_frame(ctx, snap, 2)

    assert {:ok, :inserted} =
             EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

    assert {:ok, :replay} =
             EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

    rows = workload_rows(ctx)

    assert Enum.map(rows, & &1.container_id) == ["container-alpha", "container-beta"]

    [alpha, beta] = rows
    assert alpha.pod_uid == "pod-uid-alpha"
    assert alpha.pod_namespace == "payments"
    assert alpha.pod_name == "checkout-api-6d8d9b7f44-k9znm"
    assert alpha.container_name == "checkout-api"
    assert alpha.image == "registry.example.com/checkout-api:1.2.3"
    assert alpha.runtime_source == "Containerd"
    assert alpha.confidence == "High"
    assert alpha.degradation_reason == nil
    assert alpha.identity["runtime_pid"] == 4312
    assert alpha.identity["context_name"] == "example-ctx"
    assert alpha.identity["snapshot_degradation_reason"] == nil

    assert alpha.identity["snapshot_endpoint"] == %{
             "type" => "Cri",
             "endpoint" => %{
               "path" => "/run/containerd/containerd.sock",
               "source" => "CommonPath"
             }
           }

    assert beta.pod_uid == "pod-uid-beta"
    assert beta.pod_namespace == "jobs"
    assert beta.pod_name == "worker-79f58f48c7-lw2kq"
    assert beta.container_name == "worker"
    assert beta.runtime_source == "Containerd"
    assert beta.confidence == "Medium"
    assert beta.degradation_reason == "runtime pid missing"
    assert beta.identity["runtime_pid"] == nil
  end

  test "ingests an empty disabled WorkloadIdentitySnapshotV1 record with projected_row_count 1",
       ctx do
    snap = %WorkloadIdentitySnapshotV1{
      observed_at_unix_nano: 1_780_000_000_000_000_000,
      enabled: false,
      count: 0,
      identities: [],
      degradation_reason: "workload identity collection disabled"
    }

    frame = build_frame(ctx, snap, 1)

    assert {:ok, :inserted} =
             EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

    assert workload_rows(ctx) == []
  end

  test "refuses a WorkloadIdentitySnapshotV1 record when the standing grant is revoked", ctx do
    snap = %WorkloadIdentitySnapshotV1{
      observed_at_unix_nano: 1_780_000_000_000_000_000,
      enabled: true,
      count: 1,
      identities: [
        %WorkloadIdentityContainerLookupV1{
          container_id: "container-revoked",
          identity: %WorkloadIdentityRecordV1{
            container_id: "container-revoked",
            pod_name: "revoked-pod",
            pod_namespace: "default",
            runtime_source: "Containerd",
            confidence: "High"
          }
        }
      ]
    }

    frame = build_frame(ctx, snap, 1)

    {:ok, _grant} =
      OutputGrants.reconcile(
        ctx.agent_id,
        @workload_identity_contract,
        ctx.partition.id,
        false
      )

    assert {:error, :output_grant_not_current} =
             EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

    assert workload_rows(ctx) == []
  end

  test "Projectors.WorkloadIdentity.decode/1 refuses malformed snapshots", ctx do
    snap = %WorkloadIdentitySnapshotV1{
      observed_at_unix_nano: 1_780_000_000_000_000_000,
      enabled: true,
      count: 1,
      identities: [
        %WorkloadIdentityContainerLookupV1{
          container_id: "container-1",
          identity: %WorkloadIdentityRecordV1{container_id: "container-1"}
        }
      ]
    }

    frame = build_frame(ctx, snap, 1)
    assert {:ok, ^snap} = WorkloadIdentityProjector.decode(frame.record)

    assert {:error, :workload_identity_snapshot_row_count} =
             WorkloadIdentityProjector.decode(%{frame.record | projected_row_count: 2})

    assert {:error, :unsupported_payload_family} =
             WorkloadIdentityProjector.decode(%{
               frame.record
               | payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_PROTOBUF_MESSAGE_V1
             })

    missing_container = %WorkloadIdentitySnapshotV1{
      observed_at_unix_nano: 1_780_000_000_000_000_000,
      enabled: true,
      count: 1,
      identities: [
        %WorkloadIdentityContainerLookupV1{
          identity: %WorkloadIdentityRecordV1{pod_name: "no-container"}
        }
      ]
    }

    bad_frame = build_frame(ctx, missing_container, 1)

    assert {:error, :workload_identity_no_container_id} =
             WorkloadIdentityProjector.decode(bad_frame.record)
  end

  defp build_frame(ctx, %WorkloadIdentitySnapshotV1{} = snap, rows) do
    {:ok, grant} =
      OutputGrants.reconcile(
        ctx.agent_id,
        @workload_identity_contract,
        ctx.partition.id,
        true
      )

    payload = WorkloadIdentitySnapshotV1.encode(snap)
    now = DateTime.utc_now()

    contract = %{
      contract_id: @workload_identity_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "workload-identity-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 10_000 * @write_bytes_per_row
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
      projected_row_count: rows,
      projected_write_bytes: rows * 2_048,
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

    %{record: record, record_bytes: record_bytes, headers: headers, slot: slot}
  end

  defp workload_rows(ctx) do
    %{columns: columns, rows: rows} =
      Repo.query!(
        """
        SELECT container_id, gateway_id, pod_uid, pod_namespace, pod_name, container_name,
               image, runtime_source, confidence, degradation_reason, identity
        FROM platform.workload_identity_current
        WHERE partition = $1 AND agent_id = $2
        ORDER BY container_id
        """,
        [ctx.partition.slug, ctx.agent_id]
      )

    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &Map.new(Enum.zip(keys, &1)))
  end

  defp stored_ack do
    test = self()

    fn subject, body, request_opts ->
      send(test, {:metrics_published, subject, body, request_opts})
      {:ok, %{body: ~s({"stream":"metrics","seq":1})}}
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
end
