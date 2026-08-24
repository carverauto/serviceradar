defmodule ServiceRadar.Inventory.Discovery.Decoders.Fingerprint do
  @moduledoc """
  Decodes a `serviceradar.netprobe.fingerprint.v1` payload into device
  observations.

  Ported from `go/pkg/agent/netprobe/translator.go`
  (`FingerprintEventToDiscoveredDevice`), whose output is pinned as golden
  fixtures so this port can be SHOWN to be behavior-preserving rather than
  asserted to be.

  A fingerprint describes whatever is at an address; it never establishes that
  anything is there. That is why the schema is registered `:enrichment_only` --
  see `SourcePolicy.enrichment_only_source?/1`, which also carries the reproduced
  over-merge this classification fixed.

  Two shapes here look like bugs and are not:

    * evidence keys are written UNCONDITIONALLY, empty strings and zeroes
      included, while `profile_id` and `interface` are dropped when empty. The
      Go translator does exactly this and consumers have been reading the empties
      for as long as the feature has existed.
    * a `license_clean` arm whose inner message is absent still emits an
      observation, with base metadata only and no `.protocol` key at all.

  This decoder emits OBSERVATIONS ONLY. It must never set `agent_id`,
  `gateway_id`, `partition` or `source` -- those are stamped by
  `DiscoveryIngestor` from gateway-attested metadata and the schema registry. A
  decoder that read identity out of the payload would let an add-on claim to be
  a different agent.

  `_alias_collector_ip` is deliberately NOT emitted. The Go translator wrote it
  from its own `TranslationOptions`; core stamps the attested `agent_id` instead,
  which identifies the collector more precisely than an address that can change.
  It only ever fed a `:collector_ip` alias row, which is a non-identity type no
  identity reader consults (`DeviceAliasState.alias_type`).
  """

  alias Serviceradar.Agent.Netprobe.V1.FingerprintEvent
  alias Serviceradar.Agent.Netprobe.V1.FingerprintEventBatch
  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  require Logger

  # The sentinel the agent's banner-grab path sets as profile_id. It selects a
  # different source AND a different metadata prefix, and suppresses profile_id
  # itself -- reporting the sentinel back as a profile would be noise.
  @sweep_active "sweep_active"

  @passive_source "passive-netprobe"
  @active_source "sweep_active"

  @type observation :: %{optional(String.t()) => term()}
  @type stats :: %{atom() => non_neg_integer()}

  @spec decode(binary()) :: {:ok, [observation()], stats()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case safe_decode(payload) do
      {:ok, %FingerprintEventBatch{events: events}} -> flatten({:ok, translate(events)})
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp flatten({:ok, {observations, stats}}), do: {:ok, observations, stats}

  defp safe_decode(payload) do
    {:ok, FingerprintEventBatch.decode(payload)}
  rescue
    error -> {:error, {:decode_failed, Exception.message(error)}}
  end

  defp translate(events) do
    events
    |> Enum.reduce(
      {[], %{events: 0, observations: 0, skipped_no_ip: 0, skipped_no_evidence: 0}},
      fn
        event, {acc, stats} ->
          stats = Map.update!(stats, :events, &(&1 + 1))

          case observation(event) do
            {:ok, observation} ->
              {[observation | acc], Map.update!(stats, :observations, &(&1 + 1))}

            {:skip, reason} ->
              {acc, Map.update(stats, reason, 1, &(&1 + 1))}
          end
      end
    )
    |> then(fn {acc, stats} -> {Enum.reverse(acc), stats} end)
  end

  defp observation(%FingerprintEvent{} = event) do
    ip = trim(event.ip)

    if ip == "" do
      {:skip, :skipped_no_ip}
    else
      case evidence_metadata(event, base_prefix(event)) do
        :none ->
          {:skip, :skipped_no_evidence}

        {:ok, evidence} ->
          {:ok,
           %{
             "ip" => ip,
             "metadata" => Map.merge(base_metadata(event, ip), evidence)
           }}
      end
    end
  end

  defp observation(_event), do: {:skip, :skipped_no_evidence}

  defp sweep_active?(%FingerprintEvent{profile_id: profile_id}),
    do: trim(profile_id) == @sweep_active

  defp base_prefix(event),
    do: if(sweep_active?(event), do: "active_fingerprint", else: "passive_fingerprint")

  defp source(event), do: if(sweep_active?(event), do: @active_source, else: @passive_source)

  # `profile_id` is blank when it IS the sentinel: the sentinel selected the
  # source and the prefix already, and echoing it back as a profile is noise.
  defp profile_id(event) do
    case trim(event.profile_id) do
      @sweep_active -> ""
      other -> other
    end
  end

  defp base_metadata(event, ip) do
    base = base_prefix(event)
    observed_at = event.observed_at_unix_nano || 0
    observed_text = Timestamps.rfc3339_nano(observed_at)

    %{}
    |> Map.put("#{base}.source", source(event))
    |> Map.put("_alias_last_seen_ip", ip)
    |> Map.put("ip_alias:" <> ip, observed_text)
    |> put_unless_empty("#{base}.profile_id", profile_id(event))
    |> put_unless_empty("#{base}.interface", trim(event.interface_name))
    |> put_observed_at(base, observed_at, observed_text)
  end

  defp put_observed_at(metadata, _base, observed_at, _text) when observed_at <= 0, do: metadata

  defp put_observed_at(metadata, base, observed_at, text) do
    metadata
    |> Map.put("#{base}.observed_at", text)
    |> Map.put("#{base}.observed_at_unix_nano", Integer.to_string(observed_at))
    |> Map.put("_alias_last_seen_at", text)
  end

  defp evidence_metadata(%FingerprintEvent{evidence: {:tcp, tcp}}, base) when not is_nil(tcp) do
    {:ok,
     %{
       "#{base}.protocol" => "tcp",
       "#{base}.tcp.signature" => trim(tcp.signature),
       "#{base}.tcp.os_family" => trim(tcp.os_family),
       "#{base}.tcp.os_name" => trim(tcp.os_name),
       "#{base}.tcp.window_size" => trim(tcp.window_size),
       "#{base}.tcp.ip_version" => trim(tcp.ip_version),
       "#{base}.tcp.payload_class" => trim(tcp.payload_class),
       "#{base}.tcp.confidence" => confidence(tcp.confidence),
       "#{base}.tcp.ttl" => Integer.to_string(tcp.ttl || 0),
       "#{base}.tcp.mss" => Integer.to_string(tcp.mss || 0),
       "#{base}.tcp.window_scale" => Integer.to_string(tcp.window_scale || 0),
       "#{base}.tcp.options_layout" => Enum.join(tcp.options_layout || [], ","),
       "#{base}.tcp.quirks" => Enum.join(tcp.quirks || [], ",")
     }}
  end

  defp evidence_metadata(%FingerprintEvent{evidence: {:tls, tls}}, base) when not is_nil(tls) do
    {:ok,
     %{
       "#{base}.protocol" => "tls",
       "#{base}.tls.ja4" => trim(tls.ja4),
       "#{base}.tls.ja4s" => trim(tls.ja4s),
       "#{base}.tls.sni_redacted" => sni_redacted(tls.sni_redacted)
     }}
  end

  defp evidence_metadata(%FingerprintEvent{evidence: {:http, http}}, base)
       when not is_nil(http) do
    {:ok,
     %{
       "#{base}.protocol" => "http",
       "#{base}.http.user_agent" => trim(http.user_agent),
       "#{base}.http.server" => trim(http.server),
       "#{base}.http.accept_language" => trim(http.accept_language)
     }}
  end

  # Defensive only: a decoded oneof yields an empty message, never nil, because a
  # nil inner cannot be encoded. Kept so a library that does hand back nil
  # degrades to "no evidence detail" rather than crashing the batch.
  defp evidence_metadata(%FingerprintEvent{evidence: {:license_clean, nil}}, _base),
    do: {:ok, %{}}

  defp evidence_metadata(%FingerprintEvent{evidence: {:license_clean, clean}}, base) do
    {:ok,
     %{"#{base}.protocol" => "license_clean"}
     |> Map.merge(os_match_metadata(clean.os_match, base))
     |> Map.merge(recog_metadata(clean, base))}
  end

  defp evidence_metadata(_event, _base), do: :none

  defp os_match_metadata(nil, _base), do: %{}

  defp os_match_metadata(os_match, base) do
    %{
      "#{base}.os.name" => trim(os_match.name),
      "#{base}.os.version_range" => trim(os_match.version_range),
      "#{base}.os.family" => trim(os_match.os_family),
      "#{base}.os.confidence" => confidence(os_match.confidence)
    }
  end

  # Order matches the Go translator's; it does not affect the map, but a reader
  # comparing the two files should not have to reorder them in their head.
  @recog_protocols [
    {:recog_http, "http"},
    {:recog_ssh, "ssh"},
    {:recog_smb, "smb"},
    {:recog_ftp, "ftp"},
    {:recog_telnet, "telnet"},
    {:recog_smtp, "smtp"},
    {:recog_rdp, "rdp"},
    {:recog_dns, "dns"},
    {:recog_ntp, "ntp"}
  ]

  defp recog_metadata(clean, base) do
    Enum.reduce(@recog_protocols, %{}, fn {field, protocol}, acc ->
      case Map.get(clean, field) do
        nil ->
          acc

        match ->
          prefix = "#{base}.recog.#{protocol}"

          Map.merge(acc, %{
            "#{prefix}.product" => trim(match.product),
            "#{prefix}.version" => trim(match.version),
            "#{prefix}.os_family" => trim(match.os_family)
          })
      end
    end)
  end

  # Go: strconv.FormatFloat(float64(f32), 'f', 3, 32)
  defp confidence(nil), do: "0.000"
  defp confidence(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  # Never emits a real SNI: anything non-empty becomes the presence marker.
  defp sni_redacted(value) do
    case trim(value) do
      "" -> ""
      _ -> "<present>"
    end
  end

  defp put_unless_empty(map, _key, ""), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
