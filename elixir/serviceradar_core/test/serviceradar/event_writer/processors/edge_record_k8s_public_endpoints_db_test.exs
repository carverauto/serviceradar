defmodule ServiceRadar.EventWriter.Processors.EdgeRecordK8sPublicEndpointsDbTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.K8sBackendRefV1
  alias Serviceradar.Edge.V1.K8sCorrelationHintV1
  alias Serviceradar.Edge.V1.K8sEndpointTargetV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointsSnapshotV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @contract_id "serviceradar.k8s.public_endpoints.snapshot"
  @write_bytes_per_row 8_192

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    OutputGrants.reset_cache()
    scope_id = Ecto.UUID.generate()
    cluster_id = "k8s-edge-cluster-#{System.unique_integer([:positive])}"
    agent_id = "agent-k8s-edge-#{System.unique_integer([:positive])}"
    rogue_agent_id = "agent-k8s-rogue-#{System.unique_integer([:positive])}"

    insert_agent!(agent_id)
    insert_agent!(rogue_agent_id)
    insert_cluster_binding!(cluster_id, agent_id, scope_id)

    on_exit(fn ->
      cleanup(scope_id, cluster_id, [agent_id, rogue_agent_id])
    end)

    {:ok,
     scope_id: scope_id,
     cluster_id: cluster_id,
     agent_id: agent_id,
     rogue_agent_id: rogue_agent_id}
  end

  test "projects K8sPublicEndpointsSnapshotV1 into public_endpoints_current and k8s_public_endpoint_snapshots and soft-deletes missing endpoints",
       %{scope_id: scope_id, cluster_id: cluster_id, agent_id: agent_id} do
    grant = grant_for(agent_id, scope_id)

    snap1 = %K8sPublicEndpointsSnapshotV1{
      schema_version: "serviceradar.k8s_public_endpoints.v1",
      agent_id: agent_id,
      cluster_id: cluster_id,
      generated_at: "2026-07-01T12:00:00Z",
      content_hash: String.duplicate("a", 64),
      endpoints: [
        %K8sPublicEndpointV1{
          cluster_id: cluster_id,
          ip: "192.0.2.10",
          hostname: "ingress.example.com",
          port: 443,
          protocol: "TCP",
          exposure_class: "LoadBalancer",
          external_traffic_policy: "Local",
          metallb_pool: "public-v4",
          load_balancer_ip_mode: "VIP",
          namespace: "ingress-system",
          service_name: "edge-gw",
          service_uid: "uid-svc-1",
          gateway_name: "main-gw",
          gateway_class: "cilium",
          listener_name: "https",
          route_kind: "HTTPRoute",
          route_name: "app-route",
          service_target_port: 8443,
          service_target_name: "https-target",
          annotations: %{"metallb.universe.tf/address-pool" => "public-v4"},
          observed_at: "2026-07-01T12:00:00Z",
          backend_refs: [
            %K8sBackendRefV1{
              group: "",
              kind: "Service",
              namespace: "app-ns",
              name: "app-svc",
              port: 8080,
              weight: 100
            }
          ],
          endpoint_targets: [
            %K8sEndpointTargetV1{
              ip: "192.0.2.50",
              port: 8080,
              protocol: "TCP",
              pod_namespace: "app-ns",
              pod_name: "app-pod-1",
              node_name: "node-1",
              ready: true
            }
          ]
        },
        %K8sPublicEndpointV1{
          cluster_id: cluster_id,
          ip: "192.0.2.11",
          port: 80,
          protocol: "TCP",
          exposure_class: "LoadBalancer",
          namespace: "ingress-system",
          service_name: "edge-http",
          observed_at: "2026-07-01T12:00:00Z"
        }
      ],
      correlation_hints: [
        %K8sCorrelationHintV1{
          public_ip: "192.0.2.10",
          public_hostname: "ingress.example.com",
          public_port: 443,
          protocol: "TCP",
          backend_ip: "192.0.2.50",
          backend_port: 8080,
          pod_namespace: "app-ns",
          pod_name: "app-pod-1",
          node_name: "node-1",
          namespace: "ingress-system",
          service_name: "edge-gw",
          gateway_name: "main-gw",
          route_kind: "HTTPRoute",
          route_name: "app-route",
          exposure_class: "LoadBalancer"
        }
      ]
    }

    {msg1, _bytes1, _headers1} =
      build_message(
        K8sPublicEndpointsSnapshotV1.encode(snap1),
        2,
        grant,
        scope_id,
        agent_id,
        1
      )

    assert {:ok, 1} = EdgeRecord.process_batch([msg1])

    assert %{
             rows: [
               ["192.0.2.10", 443, "edge-gw", 8443, nil],
               ["192.0.2.11", 80, "edge-http", nil, nil]
             ]
           } =
             Repo.query!(
               """
               SELECT ip, port, service_name, service_target_port, deleted_at
               FROM platform.public_endpoints_current
               WHERE cluster_id = $1
               ORDER BY ip
               """,
               [cluster_id]
             )

    assert %{rows: [[^cluster_id, "agent", ^agent_id, ^scope_id]]} =
             Repo.query!(
               """
               SELECT cluster_id, source_mode, agent_id, partition_id
               FROM platform.k8s_public_endpoint_snapshots
               WHERE cluster_id = $1
               """,
               [cluster_id]
             )

    # Empty-endpoints snapshot (projected_row_count = 1) soft-deletes previous endpoints.
    snap2 = %K8sPublicEndpointsSnapshotV1{
      schema_version: "serviceradar.k8s_public_endpoints.v1",
      agent_id: agent_id,
      cluster_id: cluster_id,
      generated_at: "2026-07-01T12:05:00Z",
      endpoints: []
    }

    {msg2, _bytes2, _headers2} =
      build_message(
        K8sPublicEndpointsSnapshotV1.encode(snap2),
        1,
        grant,
        scope_id,
        agent_id,
        2
      )

    assert {:ok, 1} = EdgeRecord.process_batch([msg2])

    assert %{rows: [[0, 2]]} =
             Repo.query!(
               """
               SELECT
                 COUNT(*) FILTER (WHERE deleted_at IS NULL),
                 COUNT(*) FILTER (WHERE deleted_at IS NOT NULL)
               FROM platform.public_endpoints_current
               WHERE cluster_id = $1
               """,
               [cluster_id]
             )
  end

  test "refuses a snapshot from an agent not bound in k8s_inventory_cluster_bindings",
       %{scope_id: scope_id, cluster_id: cluster_id, rogue_agent_id: rogue_agent_id} do
    rogue_grant = grant_for(rogue_agent_id, scope_id)

    snap = %K8sPublicEndpointsSnapshotV1{
      schema_version: "serviceradar.k8s_public_endpoints.v1",
      agent_id: rogue_agent_id,
      cluster_id: cluster_id,
      generated_at: "2026-07-01T12:10:00Z",
      endpoints: [
        %K8sPublicEndpointV1{
          cluster_id: cluster_id,
          ip: "192.0.2.99",
          port: 443,
          protocol: "TCP",
          namespace: "rogue-ns",
          service_name: "rogue-svc"
        }
      ]
    }

    {message, bytes, headers} =
      build_message(
        K8sPublicEndpointsSnapshotV1.encode(snap),
        1,
        rogue_grant,
        scope_id,
        rogue_agent_id,
        1
      )

    assert {:ok, 0} = EdgeRecord.process_batch([message])

    assert {:error, :k8s_inventory_cluster_binding_mismatch} =
             EdgeRecord.ingest(bytes, headers, Repo)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.public_endpoints_current WHERE cluster_id = $1",
               [cluster_id]
             )
  end

  test "refuses a snapshot whose standing grant was revoked before ingestion",
       %{scope_id: scope_id, cluster_id: cluster_id, agent_id: agent_id} do
    grant = grant_for(agent_id, scope_id)

    snap = %K8sPublicEndpointsSnapshotV1{
      schema_version: "serviceradar.k8s_public_endpoints.v1",
      agent_id: agent_id,
      cluster_id: cluster_id,
      generated_at: "2026-07-01T12:15:00Z",
      endpoints: [
        %K8sPublicEndpointV1{
          cluster_id: cluster_id,
          ip: "192.0.2.10",
          port: 443,
          protocol: "TCP",
          namespace: "default",
          service_name: "svc-a"
        }
      ]
    }

    {message, bytes, headers} =
      build_message(
        K8sPublicEndpointsSnapshotV1.encode(snap),
        1,
        grant,
        scope_id,
        agent_id,
        1
      )

    {:ok, _revoked} = OutputGrants.reconcile(agent_id, @contract_id, scope_id, false)
    OutputGrants.reset_cache()

    assert {:ok, 0} = EdgeRecord.process_batch([message])
    assert {:error, :output_grant_not_current} = EdgeRecord.ingest(bytes, headers, Repo)
  end

  defp grant_for(agent_id, scope_id) do
    {:ok, %OutputGrant{} = grant} = OutputGrants.reconcile(agent_id, @contract_id, scope_id, true)
    grant
  end

  defp build_message(inner_bytes, rows, %OutputGrant{} = grant, scope_id, agent_id, sequence) do
    scope_bytes = Ecto.UUID.dump!(scope_id)
    now = DateTime.utc_now()

    contract = %{
      contract_id: @contract_id,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "k8s-endpoints-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 81_920_000
    }

    key = IssuerKey.from_seed(:binary.copy(<<0x5B>>, 32))
    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    base = %EdgeRecordV1{
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
      encoded_size: byte_size(inner_bytes),
      uncompressed_size: byte_size(inner_bytes),
      payload_sha256: :crypto.hash(:sha256, inner_bytes),
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
      network_scope_id: scope_bytes,
      projected_row_count: rows,
      projected_write_bytes: rows * @write_bytes_per_row,
      cost_model_version: 1,
      payload: inner_bytes
    }

    record = %{base | semantic_envelope_sha256: SemanticDigest.compute(base)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    slot = %{
      network_scope_id: scope_bytes,
      authenticated_agent_id: agent_id,
      spool_id: claims.producer_assignment_id,
      sequence: sequence
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

    {%{
       data: record_bytes,
       metadata: %{headers: headers, subject: "telemetry.edge-records.v1.bulk.test"}
     }, record_bytes, headers}
  end

  defp insert_agent!(agent_id) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_agents (uid, name, first_seen_time, last_seen_time, created_time, modified_time)
      VALUES ($1, $1, now(), now(), now(), now())
      ON CONFLICT (uid) DO NOTHING
      """,
      [agent_id]
    )
  end

  defp insert_cluster_binding!(cluster_id, agent_id, partition_id) do
    Repo.query!(
      """
      INSERT INTO platform.k8s_inventory_cluster_bindings
        (cluster_id, agent_id, partition_id, changed_by, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'test', now(), now())
      """,
      [cluster_id, agent_id, partition_id]
    )
  end

  defp cleanup(scope_id, cluster_id, agent_ids) do
    scope_bytes = Ecto.UUID.dump!(scope_id)

    Repo.query!("DELETE FROM platform.public_endpoints_current WHERE cluster_id = $1", [
      cluster_id
    ])

    Repo.query!("DELETE FROM platform.k8s_public_endpoint_snapshots WHERE cluster_id = $1", [
      cluster_id
    ])

    Repo.query!("DELETE FROM platform.k8s_inventory_cluster_bindings WHERE cluster_id = $1", [
      cluster_id
    ])

    Repo.query!("DELETE FROM platform.ocsf_agents WHERE uid = ANY($1::text[])", [agent_ids])

    Repo.query!("DELETE FROM platform.edge_delivery_slots WHERE network_scope_id = $1::uuid", [
      scope_bytes
    ])

    Repo.query!("DELETE FROM platform.event_ledger WHERE network_scope_id = $1::uuid", [
      scope_bytes
    ])

    Repo.query!("DELETE FROM platform.edge_output_grants WHERE network_scope_id = $1::uuid", [
      scope_bytes
    ])

    OutputGrants.reset_cache()
  end
end
