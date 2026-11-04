defmodule ServiceRadar.Edge.Projectors.EndpointInventory do
  @moduledoc """
  Projects `serviceradar.endpoint_inventory.scan` edge records into
  `ServiceRadar.Inventory.EndpointInventoryIngestorQueue.ingest_now/1`,
  the destination `service_type: "endpoint_inventory"` results have today.
  Each scan record is rebuilt as the string-keyed payload map the ingestor
  expects, binding `agent_id` from the authenticated producer context so
  device resolution, package-set reconciliation, delta application, and
  artifact persistence behave identically to the legacy status path.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXBOMV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXComponentV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXMetadataV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1
  alias Serviceradar.Edge.V1.EndpointInventoryCycloneDXToolV1
  alias Serviceradar.Edge.V1.EndpointInventoryFreshnessVerdictV1
  alias Serviceradar.Edge.V1.EndpointInventoryOSInfoV1
  alias Serviceradar.Edge.V1.EndpointInventoryPackageChangeV1
  alias Serviceradar.Edge.V1.EndpointInventoryPackageSetDeltaV1
  alias Serviceradar.Edge.V1.EndpointInventoryPackageV1
  alias Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1
  alias Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1
  alias Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Inventory.EndpointInventoryIngestorQueue

  @doc """
  Decodes and validates an endpoint inventory scan record: no source
  authorization, a host-stamped agent id, a scan id, a projected row count
  of 1, and well-formed JSON object metadata when `metadata_json` is non-empty.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %EndpointInventoryScanPayloadV1{} = scan} <-
           WireDecode.decode_endpoint_inventory_scan(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(scan.agent_id),
             :endpoint_inventory_scan_no_agent
           ),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(scan.scan_id),
             :endpoint_inventory_scan_no_scan_id
           ),
         :ok <-
           DiscoveryCommon.check(
             record.projected_row_count == 1,
             :endpoint_inventory_scan_row_count
           ),
         :ok <- check_metadata(scan.metadata_json) do
      {:ok, scan}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :endpoint_inventory_scan_source_authorization}

  @doc """
  Ingests the rebuilt endpoint inventory scan payload after checking the
  standing grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %EndpointInventoryScanPayloadV1{} = scan, _opts) do
    DiscoveryCommon.with_current_grant(record, fn agent_id ->
      payload = to_ingestor_payload(scan, agent_id)

      case EndpointInventoryIngestorQueue.ingest_now(payload) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:endpoint_inventory_ingest_failed, reason}}
      end
    end)
  end

  @doc """
  Convenience wrapper for projecting a decoded endpoint inventory scan record.
  """
  @spec project(EdgeRecordV1.t(), EndpointInventoryScanPayloadV1.t()) ::
          :ok | {:refused, term()} | {:error, term()}
  def project(%EdgeRecordV1{} = record, %EndpointInventoryScanPayloadV1{} = scan) do
    publish(record, scan, [])
  end

  @doc """
  Rebuilds the string-keyed map consumed by `EndpointInventoryIngestor.ingest_report/2`.
  """
  @spec to_ingestor_payload(EndpointInventoryScanPayloadV1.t(), String.t()) :: map()
  def to_ingestor_payload(%EndpointInventoryScanPayloadV1{} = scan, agent_id) do
    %{
      "schema_version" => scan.schema_version,
      "agent_id" => agent_id,
      "scan_id" => scan.scan_id,
      "collector_version" => scan.collector_version,
      "state" => scan.state,
      "coverage_state" => scan.coverage_state,
      "config_hash" => scan.config_hash,
      "last_scan_at" => scan.last_scan_at,
      "last_successful_scan_at" => scan.last_successful_scan_at,
      "package_set_hash" => scan.package_set_hash,
      "artifact_hash" => scan.artifact_hash,
      "hash_algorithm" => scan.hash_algorithm,
      "upload_reason" => scan.upload_reason
    }
    |> DiscoveryCommon.put_present("os", os_map(scan.os))
    |> DiscoveryCommon.put_present("sbom", sbom_map(scan.sbom))
    |> DiscoveryCommon.put_present("package_delta", package_delta_map(scan.package_delta))
    |> DiscoveryCommon.compact()
    |> Map.merge(%{
      "enabled_plugins" => scan.enabled_plugins || [],
      "detected_plugins" => scan.detected_plugins || [],
      "diagnostics" => Enum.map(scan.diagnostics || [], &diagnostic_map/1),
      "package_count" => scan.package_count || 0,
      "duration_ms" => scan.duration_ms || 0,
      "truncated" => scan.truncated == true,
      "standing_question_result_counts" =>
        Enum.map(scan.standing_question_result_counts || [], &question_count_map/1),
      "metadata" => metadata_map(scan.metadata_json)
    })
  end

  defp check_metadata(bytes) when bytes in [nil, ""], do: :ok

  defp check_metadata(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> :ok
      _ -> {:error, :endpoint_inventory_scan_metadata}
    end
  end

  defp metadata_map(bytes) when bytes in [nil, ""], do: %{}

  defp metadata_map(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp os_map(nil), do: nil

  defp os_map(%EndpointInventoryOSInfoV1{} = os) do
    DiscoveryCommon.compact(%{
      "name" => os.name,
      "id" => os.id,
      "version" => os.version,
      "version_id" => os.version_id,
      "pretty_name" => os.pretty_name
    })
  end

  defp diagnostic_map(%EndpointInventorySourceSummaryV1{} = diag) do
    base =
      %{
        "name" => diag.name,
        "type" => diag.type,
        "state" => diag.state,
        "finding_count" => if((diag.finding_count || 0) > 0, do: diag.finding_count),
        "reason" => diag.reason,
        "error" => diag.error,
        "path" => diag.path,
        "duration_ms" => if((diag.duration_ms || 0) > 0, do: diag.duration_ms),
        "truncated" => if(diag.truncated == true, do: true)
      }
      |> DiscoveryCommon.compact()
      |> Map.put("package_count", diag.package_count || 0)

    if diag.has_detected do
      Map.put(base, "detected", diag.detected)
    else
      base
    end
  end

  defp question_count_map(%EndpointInventoryStandingQuestionResultCountV1{} = entry) do
    %{
      "schema" => entry.schema,
      "question_id" => entry.question_id,
      "question_version" => entry.question_version,
      "predicate_hash" => entry.predicate_hash,
      "mode" => entry.mode,
      "package_set_hash" => entry.package_set_hash,
      "hash_algorithm" => entry.hash_algorithm,
      "evaluated_at" => entry.evaluated_at
    }
    |> DiscoveryCommon.put_present("freshness", freshness_map(entry.freshness))
    |> DiscoveryCommon.put_present("labels", entry.labels)
    |> DiscoveryCommon.put_present("metadata", entry.metadata)
    |> DiscoveryCommon.compact()
    |> Map.merge(%{
      "matched" => entry.matched == true,
      "count" => entry.count || 0
    })
  end

  defp freshness_map(nil), do: nil

  defp freshness_map(%EndpointInventoryFreshnessVerdictV1{} = f) do
    DiscoveryCommon.compact(%{
      "verdict" => f.verdict,
      "age_seconds" => if((f.age_seconds || 0) > 0, do: f.age_seconds),
      "stale_threshold_seconds" =>
        if((f.stale_threshold_seconds || 0) > 0, do: f.stale_threshold_seconds),
      "last_successful_scan_at" => f.last_successful_scan_at
    })
  end

  defp sbom_map(nil), do: nil

  defp sbom_map(%EndpointInventoryCycloneDXBOMV1{} = sbom) do
    %{
      "bomFormat" => sbom.bom_format,
      "specVersion" => sbom.spec_version,
      "serialNumber" => sbom.serial_number
    }
    |> DiscoveryCommon.put_present("metadata", sbom_metadata_map(sbom.metadata))
    |> DiscoveryCommon.put_present(
      "properties",
      Enum.map(sbom.properties || [], &sbom_property_map/1)
    )
    |> DiscoveryCommon.compact()
    |> Map.merge(%{
      "version" => if((sbom.version || 0) > 0, do: sbom.version, else: 1),
      "components" => Enum.map(sbom.components || [], &sbom_component_map/1)
    })
  end

  defp sbom_metadata_map(nil), do: nil

  defp sbom_metadata_map(%EndpointInventoryCycloneDXMetadataV1{} = meta) do
    %{"timestamp" => meta.timestamp}
    |> DiscoveryCommon.put_present("tools", Enum.map(meta.tools || [], &sbom_tool_map/1))
    |> DiscoveryCommon.put_present("component", sbom_component_map(meta.component))
    |> DiscoveryCommon.put_present(
      "properties",
      Enum.map(meta.properties || [], &sbom_property_map/1)
    )
    |> DiscoveryCommon.compact()
  end

  defp sbom_tool_map(%EndpointInventoryCycloneDXToolV1{} = tool) do
    DiscoveryCommon.compact(%{
      "vendor" => tool.vendor,
      "name" => tool.name,
      "version" => tool.version
    })
  end

  defp sbom_component_map(nil), do: nil

  defp sbom_component_map(%EndpointInventoryCycloneDXComponentV1{} = comp) do
    %{
      "type" => comp.type,
      "name" => comp.name,
      "version" => comp.version,
      "group" => comp.group,
      "purl" => comp.purl,
      "cpe" => comp.cpe
    }
    |> DiscoveryCommon.put_present(
      "properties",
      Enum.map(comp.properties || [], &sbom_property_map/1)
    )
    |> DiscoveryCommon.compact()
  end

  defp sbom_property_map(%EndpointInventoryCycloneDXPropertyV1{} = prop) do
    %{
      "name" => prop.name,
      "value" => prop.value
    }
  end

  defp package_delta_map(nil), do: nil

  defp package_delta_map(%EndpointInventoryPackageSetDeltaV1{} = delta) do
    %{
      "schema" => delta.schema,
      "base_package_set_hash" => delta.base_package_set_hash,
      "target_package_set_hash" => delta.target_package_set_hash,
      "hash_algorithm" => delta.hash_algorithm
    }
    |> DiscoveryCommon.compact()
    |> Map.merge(%{
      "added" => Enum.map(delta.added || [], &package_map/1),
      "removed" => Enum.map(delta.removed || [], &package_map/1),
      "changed" => Enum.map(delta.changed || [], &package_change_map/1)
    })
  end

  defp package_map(%EndpointInventoryPackageV1{} = pkg) do
    %{
      "name" => pkg.name,
      "version" => pkg.version,
      "architecture" => pkg.architecture,
      "manager" => pkg.manager,
      "ecosystem" => pkg.ecosystem,
      "purl" => pkg.purl
    }
    |> DiscoveryCommon.put_present("cpes", pkg.cpes)
    |> DiscoveryCommon.compact()
  end

  defp package_change_map(%EndpointInventoryPackageChangeV1{} = chg) do
    %{
      "name" => chg.name,
      "version" => chg.version,
      "architecture" => chg.architecture,
      "manager" => chg.manager,
      "ecosystem" => chg.ecosystem,
      "purl" => chg.purl,
      "previous_version" => chg.previous_version
    }
    |> DiscoveryCommon.put_present("cpes", chg.cpes)
    |> DiscoveryCommon.compact()
  end
end
