defmodule ServiceRadar.Edge.Projectors.BumblebeeScan do
  @moduledoc """
  Projects `serviceradar.bumblebee.scan` v1 records into
  `ServiceRadar.Inventory.BumblebeeIngestor.ingest_scan/2`.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.BumblebeeFindingV1
  alias Serviceradar.Edge.V1.BumblebeeScanPayloadV1
  alias Serviceradar.Edge.V1.BumblebeeSkippedRootV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Inventory.BumblebeeIngestor

  @default_schema_version "serviceradar.bumblebee.scan.v1"

  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %BumblebeeScanPayloadV1{} = scan} <- WireDecode.decode_bumblebee_scan(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(scan.agent_id),
             :bumblebee_scan_no_agent_id
           ),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(scan.run_id),
             :bumblebee_scan_no_run_id
           ),
         :ok <-
           DiscoveryCommon.check(
             max(length(scan.findings), 1) == record.projected_row_count,
             :bumblebee_scan_row_count
           ),
         :ok <- check_json_map(scan.metadata_json, :bumblebee_scan_invalid_metadata_json),
         :ok <- check_findings(scan.findings) do
      {:ok, scan}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :bumblebee_scan_source_authorization}

  @impl true
  def publish(%EdgeRecordV1{} = record, %BumblebeeScanPayloadV1{} = scan, _opts) do
    project(record, scan)
  end

  def project(%EdgeRecordV1{} = record, %BumblebeeScanPayloadV1{} = scan) do
    DiscoveryCommon.with_current_grant(record, fn agent_id ->
      scan
      |> scan_payload(agent_id)
      |> BumblebeeIngestor.ingest_scan()
      |> case do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:bumblebee_scan_ingest_failed, reason}}
      end
    end)
  end

  defp check_findings(findings) do
    Enum.reduce_while(findings, :ok, fn %BumblebeeFindingV1{} = finding, :ok ->
      with :ok <-
             DiscoveryCommon.check(
               DiscoveryCommon.present?(finding.finding_id) or
                 DiscoveryCommon.present?(finding.id),
               :bumblebee_finding_no_id
             ),
           :ok <-
             check_json_map(
               finding.evidence_json,
               :bumblebee_finding_invalid_evidence_json
             ),
           :ok <-
             check_json_map(
               finding.metadata_json,
               :bumblebee_finding_invalid_metadata_json
             ) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_json_map(raw, _reason) when raw in [nil, ""], do: :ok

  defp check_json_map(raw, reason) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> :ok
      _ -> {:error, reason}
    end
  end

  defp scan_payload(%BumblebeeScanPayloadV1{} = scan, agent_id) do
    schema_version =
      if DiscoveryCommon.present?(scan.schema_version) do
        scan.schema_version
      else
        @default_schema_version
      end

    %{
      "schema_version" => schema_version,
      "agent_id" => agent_id,
      "run_id" => scan.run_id,
      "scanner_version" => blank_to_nil(scan.scanner_version),
      "catalog_snapshot_ref" => blank_to_nil(scan.catalog_snapshot_ref),
      "state" => blank_to_nil(scan.state),
      "coverage_state" => blank_to_nil(scan.coverage_state),
      "attempted_root_count" => root_count(scan.attempted_root_count, scan.attempted_roots),
      "scanned_root_count" => root_count(scan.scanned_root_count, scan.scanned_roots),
      "skipped_root_count" => root_count(scan.skipped_root_count, scan.skipped_roots),
      "root_covered" => scan.root_covered,
      "attempted_roots" => scan.attempted_roots || [],
      "scanned_roots" => scan.scanned_roots || [],
      "skipped_roots" => Enum.map(scan.skipped_roots || [], &skipped_root_payload/1),
      "last_scan_at" => blank_to_nil(scan.last_scan_at),
      "last_successful_scan_at" => blank_to_nil(scan.last_successful_scan_at),
      "findings" => Enum.map(scan.findings || [], &finding_payload/1),
      "metadata" => decode_json_map(scan.metadata_json)
    }
  end

  defp root_count(0, roots) when is_list(roots) and roots != [], do: nil
  defp root_count(count, _roots), do: count

  defp skipped_root_payload(%BumblebeeSkippedRootV1{} = root) do
    case blank_to_nil(root.reason) do
      nil -> %{"path" => root.path}
      reason -> %{"path" => root.path, "reason" => reason}
    end
  end

  defp finding_payload(%BumblebeeFindingV1{} = finding) do
    base = %{
      "id" => blank_to_nil(finding.id),
      "finding_id" => blank_to_nil(finding.finding_id),
      "catalog_id" => blank_to_nil(finding.catalog_id),
      "severity" => blank_to_nil(finding.severity),
      "ecosystem" => blank_to_nil(finding.ecosystem),
      "package_name" => blank_to_nil(finding.package_name),
      "package_version" => blank_to_nil(finding.package_version),
      "evidence" => decode_json_map(finding.evidence_json),
      "confidence" => blank_to_nil(finding.confidence),
      "metadata" => decode_json_map(finding.metadata_json)
    }

    if finding.has_risk_score do
      Map.put(base, "risk_score", finding.risk_score)
    else
      base
    end
  end

  defp blank_to_nil(value) do
    if DiscoveryCommon.present?(value), do: value
  end

  defp decode_json_map(raw) when raw in [nil, ""], do: %{}

  defp decode_json_map(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end
end
