defmodule ServiceRadar.Inventory.DiscoveryIngestor do
  @moduledoc """
  Turns a `DiscoveryEnvelope` from a native add-on into device updates.

  This is the point where an add-on's observations become inventory, and the
  place identity is decided. Everything upstream -- add-on, agent, gateway --
  treats the payload as opaque bytes.

  ## Identity is stamped here, never read from the payload

  `agent_id`, `gateway_id` and `partition` come from the GATEWAY-ATTESTED status
  metadata. `source` and `identity_source` come from the schema registry. A
  value the add-on put in its own payload for any of these is ignored.

  That is not defensive coding for its own sake: `SourcePolicy` decides whether
  a MAC may anchor a device and whether a source may create one, and it keys on
  `source`. An add-on that could choose its own source could choose a weaker
  guardrail. `addon.proto` already states that `TelemetrySource.metadata` is
  untrusted; this is the same rule applied to the payload.

  ## An unregistered schema is a loud drop

  Not `:ok`. A schema with no registry entry has no identity policy attached, so
  ingesting it means ingesting under no guardrail. The alternative -- accepting
  it quietly -- is the failure the rest of this change exists to remove: a
  stream that reports healthy while discarding, or worse, writing everything it
  is handed.
  """

  alias Serviceradar.Agent.Discovery.V1.DiscoveryEnvelope
  alias ServiceRadar.Inventory.Discovery.Buffer
  alias ServiceRadar.Inventory.DiscoverySchemaRegistry
  alias ServiceRadar.Inventory.SyncIngestorQueue

  require Logger

  @telemetry [:serviceradar, :inventory, :discovery, :ingest]

  @type attested :: %{
          required(:agent_id) => String.t() | nil,
          required(:gateway_id) => String.t() | nil,
          required(:partition_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Ingest one discovery record's payload bytes.

  Always returns `:ok` -- a discovery payload is not worth failing a status push
  over -- but never silently: every outcome emits telemetry, and the ones that
  indicate a fault also log.
  """
  @spec ingest(binary(), attested()) :: :ok
  def ingest(payload, attested) when is_binary(payload) do
    with {:ok, envelope} <- decode_envelope(payload),
         {:ok, entry} <- lookup_schema(envelope, attested) do
      route(envelope, entry, attested)
    else
      {:error, reason} ->
        emit(reason, %{}, attested)
        :ok
    end
  end

  def ingest(_payload, attested) do
    emit(:invalid_payload, %{}, attested)
    :ok
  end

  defp decode_envelope(payload) do
    {:ok, DiscoveryEnvelope.decode(payload)}
  rescue
    _error -> {:error, :envelope_decode_failed}
  end

  defp lookup_schema(%DiscoveryEnvelope{schema: schema}, attested) do
    case DiscoverySchemaRegistry.fetch(schema) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        # Loud, with the schema name, because the fix is always "register it or
        # stop emitting it" and neither is discoverable from a silent drop.
        Logger.warning(
          "DiscoveryIngestor: dropped a payload with an unregistered schema",
          schema: inspect(schema),
          producer_id: attested[:producer_id],
          agent_id: attested[:agent_id],
          partition_id: attested[:partition_id]
        )

        {:error, :unregistered_schema}
    end
  end

  defp route(envelope, entry, attested) do
    case Buffer.offer(envelope) do
      :buffered ->
        emit(:buffered, %{parts: envelope.part_count}, attested)
        :ok

      {:dropped, reason} ->
        emit(reason, %{}, attested)
        :ok

      {:ready, payloads} ->
        decode_and_enqueue(payloads, envelope, entry, attested)
    end
  end

  # A schema whose decoder folds a payload into ONE observation per subject cannot
  # be reassembled by concatenation: every part decodes to the same subject, and
  # `build_device_upsert_records` keeps the last record per device rather than
  # merging them, so the final part would silently replace all the earlier ones.
  # Refused loudly instead. Nothing splits these today (`part_count` is 1 at the
  # producer), so this is a guard against a future chunker, not a live path.
  defp decode_and_enqueue([_ | [_ | _]] = payloads, envelope, entry, attested)
       when entry.decoder == ServiceRadar.Inventory.Discovery.Decoders.Process do
    emit(:unsplittable_schema, %{schema: envelope.schema, parts: length(payloads)}, attested)

    Logger.error(
      "Discovery: refusing a multi-part #{envelope.schema}; its decoder folds each part " <>
        "into one observation per subject, so concatenating parts would keep only the last",
      schema: envelope.schema,
      parts: length(payloads),
      agent_id: attested[:agent_id]
    )

    :ok
  end

  defp decode_and_enqueue(payloads, envelope, entry, attested) do
    decoded =
      Enum.reduce_while(payloads, {:ok, []}, fn part, {:ok, acc} ->
        case entry.decoder.decode(part) do
          {:ok, observations, _stats} -> {:cont, {:ok, acc ++ observations}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case decoded do
      {:ok, []} ->
        # A snapshot that translated to nothing is worth saying out loud: an
        # empty segment and a segment whose every sighting was rejected look
        # identical from outside, and only one of them is fine.
        emit(:empty, %{schema: envelope.schema}, attested)
        :ok

      {:ok, observations} ->
        updates = Enum.map(observations, &stamp(&1, entry, attested))

        case Jason.encode(updates) do
          {:ok, json} ->
            SyncIngestorQueue.enqueue(json)
            emit(:enqueued, %{updates: length(updates)}, attested)
            :ok

          {:error, reason} ->
            # A value that cannot be encoded must not take down the batch it
            # rides in. Drop it here, loudly, rather than at the write boundary.
            Logger.error(
              "DiscoveryIngestor: could not encode discovery updates",
              schema: inspect(envelope.schema),
              reason: inspect(reason)
            )

            emit(:encode_failed, %{}, attested)
            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "DiscoveryIngestor: decoder rejected a payload",
          schema: inspect(envelope.schema),
          reason: inspect(reason),
          agent_id: attested[:agent_id]
        )

        emit(:decode_failed, %{}, attested)
        :ok
    end
  end

  # THE identity boundary. Nothing here reads the payload.
  defp stamp(observation, entry, attested) do
    metadata =
      observation
      |> Map.get("metadata", %{})
      |> Map.put("source", entry.source)
      |> Map.put("discovery_source", entry.source)
      |> maybe_put("identity_source", entry.identity_source)
      |> maybe_put("agent_id", attested[:agent_id])
      |> maybe_put("gateway_id", attested[:gateway_id])

    observation
    |> Map.put("metadata", metadata)
    |> Map.put("source", entry.source)
    |> Map.put("partition", attested[:partition_id])
    |> maybe_put("agent_id", attested[:agent_id])
    |> maybe_put("gateway_id", attested[:gateway_id])
    |> Map.put("timestamp", DateTime.to_iso8601(DateTime.utc_now()))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(outcome, measurements, attested) do
    :telemetry.execute(
      @telemetry,
      Map.put(measurements, :count, 1),
      %{
        outcome: outcome,
        producer_id: attested[:producer_id],
        agent_id: attested[:agent_id],
        partition_id: attested[:partition_id]
      }
    )
  end
end
