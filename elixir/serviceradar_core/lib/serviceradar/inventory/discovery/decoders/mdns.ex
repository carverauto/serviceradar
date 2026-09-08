defmodule ServiceRadar.Inventory.Discovery.Decoders.Mdns do
  @moduledoc """
  Decodes a `serviceradar.netprobe.mdns.v1` payload into device observations.

  Ported from `go/pkg/agent/netprobe/mdns_translator.go`, whose output is pinned
  as golden fixtures.

  Two rules carry the design and must survive the port intact:

  * **No IP, ever.** An announcement carries an address, and this drops it. mDNS
    identifies; it does not locate. Supplying the address would let core bind a
    device to one it never verified.
  * **`mdns.model` only when there is exactly one.** A MAC advertising two
    products has not said which it is. Emitting either would let core type the
    device from whichever sorted first -- a wrong answer that looks exactly like
    a right one. Absence is the honest answer, and `mdns.models` keeps the
    evidence.

  Emits OBSERVATIONS ONLY; identity is stamped by `DiscoveryIngestor`.
  """

  alias Serviceradar.Agent.Netprobe.V1.MdnsSnapshot
  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  @metadata_prefix "mdns."

  @type observation :: %{optional(String.t()) => term()}
  @type stats :: %{atom() => non_neg_integer()}

  @spec decode(binary()) :: {:ok, [observation()], stats()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case safe_decode(payload) do
      {:ok, %MdnsSnapshot{complete: false}} -> {:error, :incomplete_snapshot}
      {:ok, %MdnsSnapshot{} = snapshot} -> translate(snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp safe_decode(payload) do
    {:ok, MdnsSnapshot.decode(payload)}
  rescue
    error -> {:error, {:decode_failed, Exception.message(error)}}
  end

  defp translate(%MdnsSnapshot{} = snapshot) do
    devices = snapshot.devices || []

    {rows, stats} =
      Enum.reduce(devices, {[], blank_stats(length(devices))}, fn device, {acc, stats} ->
        translate_device(snapshot, device, acc, stats)
      end)

    {:ok, Enum.reverse(rows), stats}
  end

  defp translate_device(snapshot, device, acc, stats) do
    mac = trimmed(device.mac)
    service_types = device.service_types || []
    txt = device.txt || []

    cond do
      mac == "" ->
        {acc, bump(stats, :skipped_no_mac)}

      service_types == [] and txt == [] ->
        # Announced nothing identifying. The census already knows this device
        # exists; mDNS has nothing to add, and emitting it would re-stamp
        # provenance no evidence supports.
        {acc, bump(stats, :skipped_no_evidence)}

      true ->
        stats =
          stats
          |> maybe_bump(:ambiguous, device.ambiguous_model)
          |> maybe_bump(:truncated, device.truncated)
          |> bump(:emitted)

        {[build_row(snapshot, device, mac) | acc], stats}
    end
  end

  # No "ip" key at all -- not an empty string. An empty value would read as a
  # claim about the address rather than the absence of one.
  defp build_row(snapshot, device, mac) do
    %{"mac" => mac, "metadata" => metadata(snapshot, device, mac)}
  end

  defp metadata(snapshot, device, mac) do
    models = device.models || []

    base = %{
      "mac" => mac,
      (@metadata_prefix <> "interface") => trimmed(snapshot.interface_name),
      (@metadata_prefix <> "snapshot_id") => trimmed(snapshot.snapshot_id),
      (@metadata_prefix <> "service_types") => Enum.join(device.service_types || [], ","),
      # Carried so an operator can see WHY a type was assigned, and so a wrong
      # assignment is traceable to the announcement that caused it.
      (@metadata_prefix <> "models") => Enum.join(models, ","),
      (@metadata_prefix <> "ambiguous_model") => to_string(!!device.ambiguous_model),
      (@metadata_prefix <> "truncated") => to_string(!!device.truncated)
    }

    base
    |> put_single_model(models)
    |> put_txt(device.txt || [])
    |> maybe_put(@metadata_prefix <> "last_seen", rfc3339(device.last_seen_unix_nano))
  end

  defp put_single_model(metadata, [model]),
    do: Map.put(metadata, @metadata_prefix <> "model", model)

  defp put_single_model(metadata, _models), do: metadata

  defp put_txt(metadata, pairs) do
    Enum.reduce(pairs, metadata, fn pair, acc ->
      case trimmed(pair.key) do
        "" ->
          acc

        key ->
          # RFC 6763 6.4: "key", "key=" and "key=value" are three states.
          # Present-with-no-value becomes "true" rather than an empty string,
          # which would claim the device sent "key=".
          value = if pair.has_value, do: pair.value || "", else: "true"
          Map.put(acc, @metadata_prefix <> "txt." <> key, value)
      end
    end)
  end

  defp maybe_put(metadata, _key, ""), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp rfc3339(nano), do: Timestamps.rfc3339_nano(nano)

  defp trimmed(nil), do: ""
  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(value), do: value |> to_string() |> String.trim()

  defp blank_stats(device_count) do
    %{
      devices: device_count,
      emitted: 0,
      skipped_no_mac: 0,
      skipped_no_evidence: 0,
      ambiguous: 0,
      truncated: 0
    }
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp maybe_bump(stats, _key, false), do: stats
  defp maybe_bump(stats, _key, nil), do: stats
  defp maybe_bump(stats, key, _truthy), do: bump(stats, key)
end
