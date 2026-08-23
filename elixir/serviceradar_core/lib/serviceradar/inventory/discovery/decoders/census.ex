defmodule ServiceRadar.Inventory.Discovery.Decoders.Census do
  @moduledoc """
  Decodes a `serviceradar.netprobe.census.v1` payload into device observations.

  Ported from the agent-side Go translator
  (`go/pkg/agent/netprobe/census_translator.go`), whose output is pinned as
  golden fixtures so this port can be shown to be behavior-preserving rather
  than asserted to be.

  The skip rules here are IDENTITY SAFETY rules, not tidiness. They lived in a
  binary that ships on a different cadence than the code owning identity policy;
  moving them next to `SourcePolicy` is the point of the change.

  This decoder emits OBSERVATIONS ONLY. It must never set `agent_id`,
  `gateway_id`, `partition` or `source` -- those are stamped by
  `DiscoveryIngestor` from gateway-attested status metadata and the schema
  registry. A decoder that read identity out of the payload would let an add-on
  claim to be a different agent.
  """

  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot
  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  require Logger

  @metadata_prefix "device_census."

  @type observation :: %{optional(String.t()) => term()}
  @type stats :: %{atom() => non_neg_integer()}

  @doc """
  Decode one census snapshot payload.

  An INCOMPLETE snapshot is refused outright: applying a fragment would read as
  "every device in the missing parts has left the segment".
  """
  @spec decode(binary()) :: {:ok, [observation()], stats()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case safe_decode(payload) do
      {:ok, %DeviceCensusSnapshot{complete: false}} ->
        {:error, :incomplete_snapshot}

      {:ok, %DeviceCensusSnapshot{} = snapshot} ->
        {:ok, observations, stats} = translate(snapshot)
        {:ok, observations, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp safe_decode(payload) do
    {:ok, DeviceCensusSnapshot.decode(payload)}
  rescue
    error -> {:error, {:decode_failed, Exception.message(error)}}
  end

  defp translate(%DeviceCensusSnapshot{} = snapshot) do
    observations = snapshot.observations || []

    {rows, stats} =
      Enum.reduce(observations, {[], blank_stats(length(observations))}, fn observation,
                                                                            {acc, stats} ->
        translate_observation(snapshot, observation, acc, stats)
      end)

    {:ok, Enum.reverse(rows), stats}
  end

  defp translate_observation(snapshot, observation, acc, stats) do
    mac = trimmed(observation.mac)

    cond do
      mac == "" ->
        # The census keys on MAC; an observation without one carries no device.
        {acc, bump(stats, :skipped_no_mac)}

      observation.off_segment ->
        # Traffic routed from another subnet arrives with the ROUTER's source
        # MAC. Emitting it would bind a remote address to the gateway's
        # hardware -- the over-merge that collapses distinct hosts onto one
        # device.
        {acc, bump(stats, :skipped_off_segment)}

      true ->
        ip = trimmed(observation.ip)

        stats =
          stats
          |> maybe_bump(:randomized_mac, observation.randomized_mac)
          |> maybe_bump(:addressless, ip == "")
          |> bump(:devices)

        {[build_row(snapshot, observation, mac, ip) | acc], stats}
    end
  end

  defp build_row(snapshot, observation, mac, ip) do
    %{
      "ip" => ip,
      "mac" => mac,
      "metadata" => metadata(snapshot, observation, mac, ip)
    }
  end

  defp metadata(snapshot, observation, mac, ip) do
    last_seen_text = rfc3339(observation.last_seen_unix_nano)

    base = %{
      # SourcePolicy.census_anchorable_mac?/1 reads metadata["mac"]. It must be
      # INSIDE the map, not only a top-level field -- an absent key fails safe
      # to "cannot anchor", which is safe but silently disables the census.
      "mac" => mac,
      (@metadata_prefix <> "interface") => trimmed(snapshot.interface_name),
      (@metadata_prefix <> "interface_index") => to_string(observation.interface_index || 0),
      (@metadata_prefix <> "kind") => kind_name(observation.kind),
      (@metadata_prefix <> "snapshot_id") => trimmed(snapshot.snapshot_id),
      (@metadata_prefix <> "first_seen_unix_nano") =>
        to_string(observation.first_seen_unix_nano || 0),
      (@metadata_prefix <> "last_seen_unix_nano") =>
        to_string(observation.last_seen_unix_nano || 0),
      # Carried explicitly even though core re-derives it from the address
      # itself. Two independent determinations that must agree is the point:
      # core's is authoritative, this one says what the observer believed.
      (@metadata_prefix <> "randomized_mac") => to_string(!!observation.randomized_mac)
    }

    base
    |> maybe_put_alias_keys(ip, last_seen_text)
    |> maybe_put("_alias_last_seen_at", last_seen_text)
  end

  # Alias keys only make sense for an observation that actually bound an
  # address. An RFC 5227 ARP probe has a MAC and no address yet; inventing an
  # empty alias for it would record a binding the device never claimed.
  defp maybe_put_alias_keys(metadata, "", _last_seen_text), do: metadata

  defp maybe_put_alias_keys(metadata, ip, last_seen_text) do
    metadata
    |> Map.put("_alias_last_seen_ip", ip)
    |> Map.put("ip_alias:" <> ip, last_seen_text)
  end

  defp maybe_put(metadata, _key, ""), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  # Mirrors censusKindName/1 in the Go translator, INCLUDING mapping an
  # unrecognised kind to "unspecified" rather than raising: netprobe may ship a
  # kind before core knows it, and a snapshot must not be lost over one label.
  defp kind_name(:DEVICE_CENSUS_KIND_ARP_REQUEST), do: "arp_request"
  defp kind_name(:DEVICE_CENSUS_KIND_ARP_REPLY), do: "arp_reply"
  defp kind_name(:DEVICE_CENSUS_KIND_IPV6_NDP), do: "ipv6_ndp"
  defp kind_name(1), do: "arp_request"
  defp kind_name(2), do: "arp_reply"
  defp kind_name(3), do: "ipv6_ndp"
  defp kind_name(_kind), do: "unspecified"

  defp rfc3339(nano), do: Timestamps.rfc3339_nano(nano)

  defp trimmed(nil), do: ""
  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(value), do: value |> to_string() |> String.trim()

  defp blank_stats(observation_count) do
    %{
      observations: observation_count,
      devices: 0,
      skipped_no_mac: 0,
      skipped_off_segment: 0,
      randomized_mac: 0,
      addressless: 0
    }
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp maybe_bump(stats, _key, false), do: stats
  defp maybe_bump(stats, _key, nil), do: stats
  defp maybe_bump(stats, key, _truthy), do: bump(stats, key)
end
