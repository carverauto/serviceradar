defmodule ServiceRadar.Inventory.Discovery.Decoders.Process do
  @moduledoc """
  Decodes a `serviceradar.netprobe.process.v1` payload into a device observation.

  Ported from `go/pkg/agent/netprobe/translator.go`
  (`ProcessSnapshotToDiscoveredDevice`), whose output is pinned as golden
  fixtures so this port can be SHOWN to be behavior-preserving.

  This payload is different in kind from the fingerprint and DPI ones beside it.
  Those describe some OTHER host the collector observed; this describes the
  collector's own listening sockets. The subject is the agent host itself, which
  is why the Go translator keyed it on `TranslationOptions.CollectorIP` rather
  than on anything in the snapshot.

  It is still registered `:enrichment_only`, and refusing closes the door on a
  process snapshot arriving with an unexpected address and creating a device from
  it.

  The original justification here claimed the agent host "always already has a
  device -- sysmon and the agent's own self-report create it". The second half was
  not true when written: there is no agent self-report source, and measured on the
  demo cluster only 15 devices out of 50,212 carry an `agent_id` identifier at all.
  A device for the agent host is minted by OBSERVER sources (mapper, sweep,
  census), which is a weaker guarantee than the comment implied. See
  `openspec/changes/add-agent-self-report-device-identity`; when that ships the
  original claim becomes true and this note can go.

  Emits OBSERVATIONS ONLY; identity is stamped by `DiscoveryIngestor`.

  ## The address

  `ProcessSnapshotBatch.subject_ip` carries it, IN the payload. It has to travel
  there rather than out of band, because `DiscoveryIngestor.decode_and_enqueue/4`
  hands a decoder payload bytes and nothing else -- an earlier version of this
  module took the subject as a second argument and was therefore never called
  with one, so it skipped every snapshot it was given.

  Empty is a drop rather than a guess: attaching a host's process listing to the
  wrong device is worse than not attaching it.
  """

  alias Serviceradar.Agent.Netprobe.V1.ProcessSnapshot
  alias Serviceradar.Agent.Netprobe.V1.ProcessSnapshotBatch
  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  @base "local_processes"

  @type observation :: %{optional(String.t()) => term()}
  @type stats :: %{atom() => non_neg_integer()}

  @spec decode(binary()) :: {:ok, [observation()], stats()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case safe_decode(payload) do
      {:ok, %ProcessSnapshotBatch{snapshot: nil}} ->
        {:ok, [], %{snapshots: 0, observations: 0}}

      {:ok, %ProcessSnapshotBatch{snapshot: snapshot, subject_ip: subject_ip}} ->
        translate(snapshot, trim(subject_ip))

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp safe_decode(payload) do
    {:ok, ProcessSnapshotBatch.decode(payload)}
  rescue
    error -> {:error, {:decode_failed, Exception.message(error)}}
  end

  defp translate(_snapshot, ""),
    do: {:ok, [], %{snapshots: 1, observations: 0, skipped_no_subject: 1}}

  defp translate(%ProcessSnapshot{} = snapshot, ip) do
    {:ok, [%{"ip" => ip, "metadata" => metadata(snapshot, ip)}], %{snapshots: 1, observations: 1}}
  end

  defp metadata(%ProcessSnapshot{} = snapshot, ip) do
    observed_at = snapshot.observed_at_unix_nano || 0
    observed_text = Timestamps.rfc3339_nano(observed_at)

    %{
      "#{@base}.schema" => "summary_v1",
      "#{@base}.fingerprint" => trim(snapshot.fingerprint),
      "#{@base}.observed_at" => observed_text,
      "#{@base}.observed_at_unix_nano" => Integer.to_string(observed_at),
      "_alias_last_seen_ip" => ip
    }
    |> Map.merge(summary(snapshot.entries || []))
    |> put_observed_at(ip, observed_text)
  end

  defp put_observed_at(metadata, ip, ""), do: Map.put(metadata, "ip_alias:" <> ip, "")

  defp put_observed_at(metadata, ip, text) do
    metadata
    |> Map.put("_alias_last_seen_at", text)
    |> Map.put("ip_alias:" <> ip, text)
  end

  defp summary(entries) do
    entries
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(
      %{
        count: 0,
        processes: MapSet.new(),
        ports: MapSet.new(),
        protocols: MapSet.new(),
        containers: MapSet.new(),
        per_protocol: %{}
      },
      &accumulate/2
    )
    |> emit()
  end

  defp accumulate(entry, acc) do
    protocol = entry.transport_protocol |> trim() |> String.downcase()
    port = entry.local_port || 0

    acc
    |> Map.update!(:count, &(&1 + 1))
    |> update_set(:processes, identity_key(entry))
    |> update_set(:containers, trim(entry.container_id))
    |> update_set(:protocols, protocol)
    |> count_port(protocol, port)
  end

  defp count_port(acc, _protocol, port) when port <= 0, do: acc

  defp count_port(acc, "", port) do
    Map.update!(acc, :ports, &MapSet.put(&1, Integer.to_string(port)))
  end

  defp count_port(acc, protocol, port) do
    text = Integer.to_string(port)

    acc
    |> Map.update!(:ports, &MapSet.put(&1, protocol <> ":" <> text))
    |> Map.update!(:per_protocol, fn per ->
      Map.update(per, protocol, MapSet.new([text]), &MapSet.put(&1, text))
    end)
  end

  defp emit(acc) do
    base = %{
      "#{@base}.entry_count" => Integer.to_string(acc.count),
      "#{@base}.process_count" => Integer.to_string(MapSet.size(acc.processes)),
      "#{@base}.port_count" => Integer.to_string(MapSet.size(acc.ports)),
      "#{@base}.container_count" => Integer.to_string(MapSet.size(acc.containers)),
      "#{@base}.protocols" => acc.protocols |> Enum.sort() |> Enum.join(",")
    }

    # Only protocols PRESENT in this snapshot get a per-protocol count. That is
    # the Go behaviour, and it is also why `local_processes.*` went monotonic
    # before device metadata merged in the database: a protocol that disappeared
    # left its old count behind forever.
    Enum.reduce(acc.per_protocol, base, fn {protocol, ports}, out ->
      Map.put(out, "#{@base}.#{protocol}_port_count", Integer.to_string(MapSet.size(ports)))
    end)
  end

  defp identity_key(entry) do
    cond do
      (entry.tgid || 0) > 0 -> "tgid:" <> Integer.to_string(entry.tgid)
      (entry.pid || 0) > 0 -> "pid:" <> Integer.to_string(entry.pid)
      trim(entry.comm) != "" -> "comm:" <> trim(entry.comm)
      true -> ""
    end
  end

  defp update_set(acc, _key, ""), do: acc
  defp update_set(acc, key, value), do: Map.update!(acc, key, &MapSet.put(&1, value))

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
