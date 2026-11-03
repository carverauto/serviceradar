defmodule ServiceRadar.EventWriter.Processors.EdgeRecordQuarantine do
  @moduledoc """
  Reports each record the gateway published to the edge-record security-quarantine stream
  (`ServiceRadar.EventWriter.Config.edge_record_security_quarantine_stream/0`).

  A record lands there when it is signed by a compromise-revoked production or source key. It is
  never projected and this processor writes nothing: not a ledger row, not a delivery slot, not a
  domain row. A ledger row would let a compromised record hold an event id that a legitimate
  record must be free to claim.

  What it does is make the record visible. For each message it logs one warning naming the
  stream and stream sequence (the coordinates `nats stream get` takes), the edge slot and the
  record's identity, and emits `[:serviceradar, :event_writer, :edge_record, :quarantined]`.
  Acknowledging the message does not remove it: the stream keeps it under limits retention with
  `MaxAge` disabled, and only an audited operator action deletes it. The full DLQ catalog,
  retention and redrive are a later change.

  An undecodable message is still counted and logged, with the reason it could not be described.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.WireDecode

  require Logger

  @impl true
  def table_name, do: "edge_record_security_quarantine"

  @impl true
  def process_batch(messages) do
    Enum.each(messages, &report/1)
    {:ok, length(messages)}
  end

  # The fields `report/1` logs, from the transport headers and the record bytes; `:error` says why
  # a part could not be read.
  defp describe(record_bytes, headers) do
    %{}
    |> Map.merge(describe_slot(headers))
    |> Map.merge(describe_record(record_bytes))
  end

  defp report(%{data: data, metadata: metadata}) when is_binary(data) do
    metadata = metadata || %{}
    description = describe(data, Map.get(metadata, :headers, %{}))
    ack = Map.get(metadata, :jetstream_ack) || %{}

    :telemetry.execute(
      [:serviceradar, :event_writer, :edge_record, :quarantined],
      %{count: 1},
      %{publication: "security_quarantine", described: is_nil(description[:error])}
    )

    # The coordinates go in the message itself rather than in Logger metadata, which a console
    # formatter may drop: this line is the operator's handle on the record.
    fields =
      [
        stream: Map.get(ack, :stream),
        stream_sequence: Map.get(ack, :stream_sequence),
        subject: Map.get(metadata, :subject)
      ] ++ Enum.sort(Map.to_list(description))

    Logger.warning(
      "Edge record held in security quarantine: " <>
        Enum.map_join(fields, " ", fn {key, value} -> "#{key}=#{loggable(value)}" end)
    )
  end

  defp report(_message), do: :ok

  defp describe_slot(headers) do
    with {:ok, header_set} <- PublicationIdentity.extract_header_set(headers),
         {:ok, provenance} <-
           PublicationIdentity.decode_transport_provenance(header_set.provenance),
         {:edge, slot} <- {provenance.kind, provenance.slot} do
      %{
        network_scope_id: hex(slot.network_scope_id),
        authenticated_agent_id: slot.authenticated_agent_id,
        spool_id: hex(slot.spool_id),
        sequence: slot.sequence,
        gateway_id: header_set.gateway_id
      }
    else
      {:service, _slot} -> %{error: :unsupported_slot_kind}
      {:error, reason} -> %{error: {:headers, reason}}
    end
  end

  defp describe_record(record_bytes) do
    case WireDecode.decode_record(record_bytes) do
      {:ok, record} ->
        contract = record.output_contract

        %{
          event_id: hex(record.event_id),
          record_sha256: hex(:crypto.hash(:sha256, record_bytes)),
          contract_id: contract && contract.contract_id,
          contract_version: contract && contract.contract_version,
          production_issuer_key_id: issuer_key_id(record.production_capability)
        }

      {:error, reason} ->
        %{error: {:record, reason}, record_sha256: hex(:crypto.hash(:sha256, record_bytes))}
    end
  end

  defp issuer_key_id(%{issuer_key_id: key_id}), do: hex(key_id)
  defp issuer_key_id(_capability), do: nil

  @log_controls ~r/[\x00-\x1F\x7F-\x9F\x{2028}\x{2029}]/u

  defp loggable(nil), do: "-"
  defp loggable(value) when is_integer(value), do: Integer.to_string(value)

  defp loggable(value) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        hex(value)

      String.match?(value, @log_controls) ->
        String.replace(value, @log_controls, &escape_control/1)

      String.printable?(value) ->
        value

      true ->
        hex(value)
    end
  end

  defp loggable(value), do: inspect(value)

  defp escape_control("\n"), do: "\\n"
  defp escape_control("\r"), do: "\\r"
  defp escape_control("\t"), do: "\\t"

  defp escape_control(<<codepoint::utf8>>) do
    "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")
  end

  defp hex(value) when is_binary(value), do: Base.encode16(value, case: :lower)
  defp hex(value), do: value
end
