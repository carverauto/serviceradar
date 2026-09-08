defmodule ServiceRadar.Inventory.Discovery.Decoders.Dpi do
  @moduledoc """
  Decodes a `serviceradar.netprobe.dpi.v1` payload into device observations.

  Ported from `go/pkg/agent/netprobe/translator.go`
  (`DpiEventToDiscoveredDevice`), whose output is pinned as golden fixtures so
  this port can be SHOWN to be behavior-preserving.

  Registered `:enrichment_only`, and more emphatically than the fingerprint
  schema: a DPI event's natural subject is a 5-tuple, not a device, so the
  address below is a CHOICE between two endpoints rather than an observation of
  one thing. Allowing that choice to create devices would mint one per arbitrary
  internet peer.

  Unlike the fingerprint decoder, `profile_id` and `interface` are written even
  when empty -- the Go translator builds them into the literal map with no
  delete-if-empty pass. Reproduced rather than tidied.

  Emits OBSERVATIONS ONLY; identity is stamped by `DiscoveryIngestor`. See the
  Fingerprint decoder for why `_alias_collector_ip` is deliberately not emitted.
  """

  alias Serviceradar.Agent.Netprobe.V1.DpiEvent
  alias Serviceradar.Agent.Netprobe.V1.DpiEventBatch
  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  @source "passive-netprobe"
  @base "dpi"

  @type observation :: %{optional(String.t()) => term()}
  @type stats :: %{atom() => non_neg_integer()}

  @spec decode(binary()) :: {:ok, [observation()], stats()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case safe_decode(payload) do
      {:ok, %DpiEventBatch{events: events, subject_ips: subject_ips}} ->
        {observations, stats} = translate(events, subject_ips || [])
        {:ok, observations, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp safe_decode(payload) do
    {:ok, DpiEventBatch.decode(payload)}
  rescue
    error -> {:error, {:decode_failed, Exception.message(error)}}
  end

  defp translate(events, subject_ips) do
    events
    |> Enum.with_index()
    |> Enum.reduce(
      {[], %{events: 0, observations: 0, skipped_no_protocol: 0, skipped_no_ip: 0}},
      fn
        {event, index}, {acc, stats} ->
          stats = Map.update!(stats, :events, &(&1 + 1))

          case observation(event, Enum.at(subject_ips, index)) do
            {:ok, observation} ->
              {[observation | acc], Map.update!(stats, :observations, &(&1 + 1))}

            {:skip, reason} ->
              {acc, Map.update(stats, reason, 1, &(&1 + 1))}
          end
      end
    )
    |> then(fn {acc, stats} -> {Enum.reverse(acc), stats} end)
  end

  defp observation(%DpiEvent{} = event, chosen_subject) do
    protocol = event.protocol |> trim() |> String.downcase()
    ip = subject_ip(event, chosen_subject)

    cond do
      protocol == "" -> {:skip, :skipped_no_protocol}
      ip == "" -> {:skip, :skipped_no_ip}
      true -> {:ok, %{"ip" => ip, "metadata" => metadata(event, ip, protocol)}}
    end
  end

  defp observation(_event, _chosen_subject), do: {:skip, :skipped_no_protocol}

  # A DPI event has two endpoints and the device is a choice between them. The
  # collector's own address wins when it is EITHER one -- and only netprobe can
  # apply that rule, because only netprobe knows its own address. So it makes the
  # choice and sends it in `subject_ips`, positionally aligned with `events`.
  #
  # The fallback is source-then-destination, which is what core can work out
  # alone. It is reached when the producer is too old to send a subject, or sent
  # an empty one -- and it is WRONG whenever the collector was the destination,
  # which is precisely why the choice moved to the producer.
  defp subject_ip(%DpiEvent{} = event, chosen_subject) do
    case trim(chosen_subject) do
      "" ->
        case trim(event.source_ip) do
          "" -> trim(event.destination_ip)
          source -> source
        end

      chosen ->
        chosen
    end
  end

  defp metadata(%DpiEvent{} = event, ip, protocol) do
    observed_at = event.observed_at_unix_nano || 0
    observed_text = Timestamps.rfc3339_nano(observed_at)

    put_observed_at(
      %{
        "#{@base}.source" => @source,
        "#{@base}.profile_id" => trim(event.profile_id),
        "#{@base}.interface" => trim(event.interface_name),
        "#{@base}.protocol" => protocol,
        "#{@base}.#{protocol}.count" => "1",
        "#{@base}.#{protocol}.confidence" => confidence(event.confidence),
        "_alias_last_seen_ip" => ip
      },
      ip,
      protocol,
      observed_at,
      observed_text
    )
  end

  defp put_observed_at(metadata, ip, _protocol, observed_at, _text) when observed_at <= 0,
    do: Map.put(metadata, "ip_alias:" <> ip, "")

  defp put_observed_at(metadata, ip, protocol, _observed_at, text) do
    metadata
    |> Map.put("#{@base}.#{protocol}.last_observed_at", text)
    |> Map.put("#{@base}.observed_at", text)
    |> Map.put("_alias_last_seen_at", text)
    |> Map.put("ip_alias:" <> ip, text)
  end

  defp confidence(nil), do: "0.000"
  defp confidence(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
