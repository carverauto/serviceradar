defmodule ServiceRadar.Edge.Projectors.WorkloadIdentity do
  @moduledoc """
  Projects `serviceradar.workload_identity.snapshot` edge records into
  `ServiceRadar.WorkloadIdentity.persist_snapshot/1`, the destination
  `source: "workload-identity"` statuses have today.
  Each snapshot record is rebuilt as the JSON snapshot payload map the legacy
  status push carried, with `agent_id` and `partition` taken from the
  authenticated edge record envelope.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1
  alias Serviceradar.Edge.V1.WorkloadIdentityRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotEndpointV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.WorkloadIdentity, as: WorkloadIdentityStore

  @doc """
  Decodes and validates a workload identity snapshot record: no source
  authorization, `RECORD_BATCH_V1` payload family, projected row count equal to
  `max(length(identities), 1)`, and every container lookup carrying a
  non-empty `container_id`.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %WorkloadIdentitySnapshotV1{} = snap} <-
           WireDecode.decode_workload_identity_snapshot(body),
         :ok <-
           DiscoveryCommon.check(
             max(length(snap.identities || []), 1) == record.projected_row_count,
             :workload_identity_snapshot_row_count
           ),
         :ok <- check_identities(snap.identities || []) do
      {:ok, snap}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :workload_identity_source_authorization}

  @doc """
  Persists the rebuilt workload identity snapshot after checking the standing
  grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %WorkloadIdentitySnapshotV1{} = snap, _opts \\ []) do
    project(record, snap)
  end

  @spec project(EdgeRecordV1.t(), WorkloadIdentitySnapshotV1.t()) ::
          :ok | {:refused, term()} | {:error, term()}
  def project(%EdgeRecordV1{} = record, %WorkloadIdentitySnapshotV1{} = snap) do
    DiscoveryCommon.with_current_grant(record, fn agent_id ->
      message = snap |> snapshot_payload() |> Jason.encode!()

      case WorkloadIdentityStore.persist_snapshot(%{
             message: message,
             agent_id: agent_id,
             partition: partition_id(record.network_scope_id)
           }) do
        :ok -> :ok
        {:error, reason} -> {:error, {:workload_identity_persist_failed, reason}}
      end
    end)
  end

  defp check_identities(identities) do
    Enum.reduce_while(identities, :ok, fn %WorkloadIdentityContainerLookupV1{} = lookup, :ok ->
      record_container_id =
        case lookup.identity do
          %WorkloadIdentityRecordV1{container_id: id} -> id
          _ -> nil
        end

      if DiscoveryCommon.present?(lookup.container_id) or
           DiscoveryCommon.present?(record_container_id) do
        {:cont, :ok}
      else
        {:halt, {:error, :workload_identity_no_container_id}}
      end
    end)
  end

  defp snapshot_payload(%WorkloadIdentitySnapshotV1{} = snap) do
    %{
      "observed_at_unix_nano" => snap.observed_at_unix_nano,
      "enabled" => snap.enabled,
      "endpoint" => endpoint_payload(snap.endpoint),
      "count" => snap.count,
      "identities" => Enum.map(snap.identities || [], &lookup_payload/1)
    }
    |> DiscoveryCommon.put_present("degradation_reason", snap.degradation_reason)
    |> DiscoveryCommon.put_present("context_name", snap.context_name)
    |> DiscoveryCommon.put_present("cluster_id", snap.cluster_id)
    |> DiscoveryCommon.put_present("cluster_name", snap.cluster_name)
  end

  defp endpoint_payload(nil), do: nil

  defp endpoint_payload(%WorkloadIdentitySnapshotEndpointV1{} = endpoint) do
    if not DiscoveryCommon.present?(endpoint.type) and
         not DiscoveryCommon.present?(endpoint.path) and
         not DiscoveryCommon.present?(endpoint.source) and
         not DiscoveryCommon.present?(endpoint.config_file_path) do
      nil
    else
      source =
        if DiscoveryCommon.present?(endpoint.config_file_path) do
          %{"ConfigFile" => endpoint.config_file_path}
        else
          present_or_nil(endpoint.source)
        end

      %{
        "type" => endpoint.type,
        "endpoint" =>
          DiscoveryCommon.compact(%{
            "path" => endpoint.path,
            "source" => source
          })
      }
    end
  end

  defp lookup_payload(%WorkloadIdentityContainerLookupV1{} = lookup) do
    rec = lookup.identity || %WorkloadIdentityRecordV1{}

    container_id =
      cond do
        DiscoveryCommon.present?(lookup.container_id) -> lookup.container_id
        DiscoveryCommon.present?(rec.container_id) -> rec.container_id
        true -> ""
      end

    record_container_id =
      if DiscoveryCommon.present?(rec.container_id), do: rec.container_id, else: container_id

    %{
      "container_id" => container_id,
      "identity" => %{
        "pod_sandbox_id" => present_or_nil(rec.pod_sandbox_id),
        "pod_name" => present_or_nil(rec.pod_name),
        "pod_namespace" => present_or_nil(rec.pod_namespace),
        "pod_uid" => present_or_nil(rec.pod_uid),
        "container_id" => record_container_id,
        "container_name" => present_or_nil(rec.container_name),
        "image" => present_or_nil(rec.image),
        "image_ref" => present_or_nil(rec.image_ref),
        "runtime_pid" => if(rec.has_runtime_pid, do: rec.runtime_pid),
        "cgroup_path" => present_or_nil(rec.cgroup_path),
        "labels" => rec.labels || %{},
        "annotations" => rec.annotations || %{},
        "runtime_source" => present_or_nil(rec.runtime_source),
        "confidence" => present_or_nil(rec.confidence),
        "degradation_reason" => present_or_nil(rec.degradation_reason)
      }
    }
  end

  defp present_or_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_or_nil(_value), do: nil

  defp partition_id(network_scope_id) do
    case Ecto.UUID.load(network_scope_id) do
      {:ok, scope_id} ->
        case Partition.get_by_id(
               scope_id,
               actor: SystemActor.system(:workload_identity_projector)
             ) do
          {:ok, %Partition{slug: slug}} when is_binary(slug) and slug != "" -> slug
          _ -> scope_id
        end

      _ ->
        "default"
    end
  end
end
