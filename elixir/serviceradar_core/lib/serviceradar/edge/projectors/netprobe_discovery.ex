defmodule ServiceRadar.Edge.Projectors.NetprobeDiscovery do
  @moduledoc """
  Projects `serviceradar.netprobe.discovery.batch` edge records into the
  sync ingestion pipeline, the destination `passive-netprobe` results
  have today (the pipeline where the census/source policy guardrails are
  consulted). Each batch is rebuilt as the JSON update array the legacy
  status push carried; the record metadata -- what the fingerprint, DPI
  and process payload schemas read -- rides verbatim.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.NetprobeDiscoveryBatchV1
  alias Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1
  alias ServiceRadar.Edge.WireDecode

  @doc """
  Decodes and validates a netprobe discovery batch: no source
  authorization, at least one record, one projected row per record, and
  per record the subject ip and originating agent id.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %NetprobeDiscoveryBatchV1{} = batch} <-
           WireDecode.decode_netprobe_discovery_batch(body),
         :ok <- DiscoveryCommon.check(batch.records != [], :netprobe_discovery_batch_empty),
         :ok <-
           DiscoveryCommon.check(
             length(batch.records) == record.projected_row_count,
             :netprobe_discovery_batch_row_count
           ),
         :ok <- check_records(batch.records) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :netprobe_discovery_batch_source_authorization}

  @doc """
  Schedules the rebuilt payload for sync ingestion after checking the
  standing grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %NetprobeDiscoveryBatchV1{} = batch, _opts) do
    DiscoveryCommon.with_current_grant(record, fn _agent_id ->
      batch.records
      |> Enum.map(&record_update/1)
      |> DiscoveryCommon.encode_updates()
      |> DiscoveryCommon.schedule_sync_ingestion()
    end)
  end

  defp check_records(records) do
    Enum.reduce_while(records, :ok, fn %NetprobeDiscoveryRecordV1{} = record, :ok ->
      cond do
        not DiscoveryCommon.present?(record.ip) ->
          {:halt, {:error, :netprobe_record_no_ip}}

        not DiscoveryCommon.present?(record.agent_id) ->
          {:halt, {:error, :netprobe_record_no_agent}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp record_update(%NetprobeDiscoveryRecordV1{} = record) do
    DiscoveryCommon.compact(%{
      "ip" => record.ip,
      "agent_id" => record.agent_id,
      "gateway_id" => record.gateway_id,
      "partition" => record.partition,
      "source" => record.source,
      "metadata" => record.metadata || %{},
      "timestamp" => DiscoveryCommon.iso8601(record.timestamp_unix_nano)
    })
  end
end
