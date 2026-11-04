defmodule ServiceRadar.Edge.Projectors.K8sPublicEndpoints do
  @moduledoc """
  Projects `serviceradar.k8s.public_endpoints.snapshot` v1 edge records into
  `ServiceRadar.EventWriter.Processors.K8sPublicEndpoints`, the destination
  agent-forwarded Kubernetes public endpoint snapshots have today.

  Each snapshot is rebuilt as the JSON snapshot payload the legacy gateway
  publisher (`ServiceRadarAgentGateway.K8sPublicEndpointsPublisher`) forwarded,
  stamped with the authenticated agent identity and partition headers from the
  record's producer context and network scope, so `Processors.K8sPublicEndpoints`
  enforces `platform.k8s_inventory_cluster_bindings`, upserts
  `platform.public_endpoints_current`, soft-deletes missing cluster endpoints,
  and updates `platform.k8s_public_endpoint_snapshots` identically.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.K8sBackendRefV1
  alias Serviceradar.Edge.V1.K8sCorrelationHintV1
  alias Serviceradar.Edge.V1.K8sEndpointTargetV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointsSnapshotV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.Processors.K8sPublicEndpoints, as: K8sPublicEndpointsProcessor
  alias ServiceRadar.Infrastructure.Partition

  @default_schema_version "serviceradar.k8s_public_endpoints.v1"

  @doc """
  Decodes and validates a Kubernetes public endpoints snapshot record: no
  source authorization, a non-empty `cluster_id`, a projected row count equal
  to `max(length(snap.endpoints), 1)`, and every endpoint's `cluster_id`
  either empty or equal to `snap.cluster_id`.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %K8sPublicEndpointsSnapshotV1{} = snap} <-
           WireDecode.decode_k8s_public_endpoints_snapshot(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(snap.cluster_id),
             :k8s_public_endpoints_no_cluster_id
           ),
         :ok <-
           DiscoveryCommon.check(
             snapshot_rows(snap) == record.projected_row_count,
             :k8s_public_endpoints_row_count
           ),
         :ok <-
           DiscoveryCommon.check(
             valid_generated_at?(snap.generated_at),
             :k8s_public_endpoints_generated_at
           ),
         :ok <- check_endpoints(snap.endpoints, snap.cluster_id) do
      {:ok, snap}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :k8s_public_endpoints_source_authorization}

  @doc """
  Ingests the rebuilt Kubernetes public endpoints snapshot after checking that
  the standing grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %K8sPublicEndpointsSnapshotV1{} = snap, _opts) do
    project(record, snap)
  end

  @doc """
  Checks that the record's standing grant is current, rebuilds the snapshot
  JSON map, and invokes `ServiceRadar.EventWriter.Processors.K8sPublicEndpoints.ingest_message/1`
  with authenticated agent/partition attribution headers.
  """
  @spec project(EdgeRecordV1.t(), K8sPublicEndpointsSnapshotV1.t()) ::
          :ok | {:refused, term()} | {:error, term()}
  def project(%EdgeRecordV1{} = record, %K8sPublicEndpointsSnapshotV1{} = snap) do
    DiscoveryCommon.with_current_grant(record, fn agent_id ->
      with {:ok, partition_id} <- partition_id(record.network_scope_id) do
        payload = snapshot_payload(snap, agent_id)

        message = %{
          data: Jason.encode!(payload),
          metadata: %{
            headers: [
              {"Sr-Ingest-Identity", "agent:" <> agent_id},
              {"Sr-Agent-Id", agent_id},
              {"Sr-Partition", partition_id}
            ]
          }
        }

        case K8sPublicEndpointsProcessor.ingest_message(message) do
          {:ok, _count} ->
            :ok

          {:error, :k8s_inventory_cluster_binding_mismatch} ->
            {:refused, :k8s_inventory_cluster_binding_mismatch}

          {:error, :invalid_k8s_public_endpoints_snapshot} ->
            {:refused, :invalid_k8s_public_endpoints_snapshot}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  defp snapshot_rows(%K8sPublicEndpointsSnapshotV1{endpoints: endpoints}) do
    max(length(endpoints || []), 1)
  end

  defp check_endpoints(endpoints, cluster_id) do
    Enum.reduce_while(endpoints || [], :ok, fn %K8sPublicEndpointV1{} = ep, :ok ->
      if ep.cluster_id in ["", cluster_id] do
        {:cont, :ok}
      else
        {:halt, {:error, :k8s_public_endpoints_endpoint_cluster_mismatch}}
      end
    end)
  end

  defp valid_generated_at?(""), do: true

  defp valid_generated_at?(generated_at) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(generated_at))
  end

  defp partition_id(network_scope_id) do
    case Ecto.UUID.load(network_scope_id) do
      {:ok, scope_id} ->
        case Partition.get_by_id(scope_id,
               actor: SystemActor.system(:k8s_public_endpoints_projector)
             ) do
          {:ok, %Partition{slug: slug}} when is_binary(slug) and slug != "" ->
            {:ok, slug}

          {:ok, _partition} ->
            {:refused, :k8s_public_endpoints_partition_not_found}

          {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
            {:refused, :k8s_public_endpoints_partition_not_found}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :k8s_public_endpoints_partition}
    end
  end

  defp snapshot_payload(%K8sPublicEndpointsSnapshotV1{} = snap, agent_id) do
    schema_version =
      if DiscoveryCommon.present?(snap.schema_version),
        do: snap.schema_version,
        else: @default_schema_version

    endpoints = Enum.map(snap.endpoints || [], &endpoint_payload/1)

    %{
      "schema_version" => schema_version,
      "agent_id" => agent_id,
      "cluster_id" => snap.cluster_id,
      "generated_at" => snap.generated_at,
      "content_hash" => snap.content_hash,
      "correlation_hints" => Enum.map(snap.correlation_hints || [], &correlation_hint_payload/1)
    }
    |> DiscoveryCommon.compact()
    |> Map.put("endpoints", endpoints)
  end

  defp endpoint_payload(%K8sPublicEndpointV1{} = ep) do
    %{
      "cluster_id" => ep.cluster_id,
      "ip" => ep.ip,
      "hostname" => ep.hostname,
      "port" => ep.port,
      "protocol" => ep.protocol,
      "exposure_class" => ep.exposure_class,
      "external_traffic_policy" => ep.external_traffic_policy,
      "metallb_pool" => ep.metallb_pool,
      "load_balancer_ip_mode" => ep.load_balancer_ip_mode,
      "namespace" => ep.namespace,
      "service_name" => ep.service_name,
      "service_uid" => ep.service_uid,
      "gateway_name" => ep.gateway_name,
      "gateway_class" => ep.gateway_class,
      "listener_name" => ep.listener_name,
      "route_kind" => ep.route_kind,
      "route_name" => ep.route_name,
      "backend_refs" => Enum.map(ep.backend_refs || [], &backend_ref_payload/1),
      "endpoint_targets" => Enum.map(ep.endpoint_targets || [], &endpoint_target_payload/1),
      "annotations" => ep.annotations || %{},
      "observed_at" => ep.observed_at
    }
    |> put_nonzero("service_target_port", ep.service_target_port)
    |> DiscoveryCommon.put_present("service_target_name", ep.service_target_name)
    |> DiscoveryCommon.compact()
  end

  defp backend_ref_payload(%K8sBackendRefV1{} = ref) do
    %{
      "group" => ref.group,
      "kind" => ref.kind,
      "namespace" => ref.namespace,
      "name" => ref.name
    }
    |> put_nonzero("port", ref.port)
    |> put_nonzero("weight", ref.weight)
    |> DiscoveryCommon.compact()
  end

  defp endpoint_target_payload(%K8sEndpointTargetV1{} = target) do
    %{
      "ip" => target.ip,
      "protocol" => target.protocol,
      "pod_namespace" => target.pod_namespace,
      "pod_name" => target.pod_name,
      "node_name" => target.node_name,
      "ready" => target.ready
    }
    |> put_nonzero("port", target.port)
    |> DiscoveryCommon.compact()
  end

  defp correlation_hint_payload(%K8sCorrelationHintV1{} = hint) do
    %{
      "public_ip" => hint.public_ip,
      "public_hostname" => hint.public_hostname,
      "public_port" => hint.public_port,
      "protocol" => hint.protocol,
      "backend_ip" => hint.backend_ip,
      "pod_namespace" => hint.pod_namespace,
      "pod_name" => hint.pod_name,
      "node_name" => hint.node_name,
      "namespace" => hint.namespace,
      "service_name" => hint.service_name,
      "gateway_name" => hint.gateway_name,
      "route_kind" => hint.route_kind,
      "route_name" => hint.route_name,
      "exposure_class" => hint.exposure_class
    }
    |> put_nonzero("backend_port", hint.backend_port)
    |> DiscoveryCommon.compact()
  end

  defp put_nonzero(map, _key, value) when value in [nil, 0], do: map
  defp put_nonzero(map, key, value), do: Map.put(map, key, value)
end
