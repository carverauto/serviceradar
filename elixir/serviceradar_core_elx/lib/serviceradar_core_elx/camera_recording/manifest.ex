defmodule ServiceRadarCoreElx.CameraRecording.Manifest do
  @moduledoc """
  Versioned recovery metadata for one sealed recording block.

  The manifest contains no local paths, bucket names, URLs or credentials. Its
  relative object keys are derived from the block identity, independent of clock
  metadata and content, so retrying conflicting content cannot choose a new key.
  The storage binding belongs to the deployment, outside this document.

  Encoding validates metadata, not remote durability. The publisher must verify
  the referenced media and init bytes, then the manifest itself, before a fenced
  index transition. Decoding is neither authorization nor proof of those bytes.
  Callers supply the expected identity from trusted state, including its clock.

  Version 1 describes the current single-track baseline H.264 path. Missing
  analysis is explicitly unknown. Bounds match the spool's absolute ceilings;
  deployment admission may be lower. Unknown versions and fields fail closed.
  """

  @max_json_bytes 2_097_152
  @max_integer 9_223_372_036_854_775_807
  @identity_keys ~w(source_id profile recorder_epoch block_sequence clock)
  @fragment_keys ~w(sequence offset length start_ns duration_ns sha256 tail_duration_source motion)

  @doc "Encode a sealed internal snapshot and actual init descriptor with storage receipts."
  def encode(
        %{sealed?: true, identity: identity, init: init, entries: entries, high_water: size, sha256: sha},
        %{sha256: init_sha, timescale: timescale, codecs: codecs},
        %{init: init_receipt, media: media_receipt}
      ) do
    with true <- is_map(init) and init["sha256"] == init_sha,
         {:ok, codec} <- codec(codecs),
         true <- is_list(entries) and length(entries) in 1..4096 do
      manifest = %{
        "version" => 1,
        "identity" => identity,
        "format" => %{"codec" => codec, "timescale" => timescale},
        "init" => object(init, init_receipt),
        "media" => object(%{"length" => size, "sha256" => sha}, media_receipt),
        "fragments" => Enum.map(entries, &fragment/1)
      }

      with :ok <- validate(manifest),
           manifest = put_object_keys(manifest),
           {:ok, bytes} <- Jason.encode(canonical(manifest)),
           true <- byte_size(bytes) <= @max_json_bytes do
        {:ok, bytes}
      else
        _ -> {:error, :invalid_manifest}
      end
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def encode(_snapshot, _format, _receipts), do: {:error, :invalid_manifest}

  @doc "Decode a bounded manifest and require the caller's exact persisted identity."
  def decode(bytes, expected_identity) when is_binary(bytes) and byte_size(bytes) <= @max_json_bytes do
    with {:ok, %{"version" => 1} = manifest} <- Jason.decode(bytes),
         true <- manifest["identity"] == expected_identity,
         :ok <- validate(manifest),
         true <- put_object_keys(manifest) == manifest do
      {:ok, manifest}
    else
      {:ok, %{"version" => _}} -> {:error, :unsupported_manifest_version}
      _ -> {:error, :invalid_manifest}
    end
  end

  def decode(_bytes, _identity), do: {:error, :invalid_manifest}

  defp validate(
         %{
           "version" => 1,
           "identity" => identity,
           "format" => format,
           "init" => init,
           "media" => media,
           "fragments" => fragments
         } = manifest
       ) do
    if map_size(manifest) == 6 and valid_identity?(identity) and valid_format?(format) and
         valid_object?(init, 1_048_576) and valid_object?(media, 536_870_912) and
         valid_fragments?(fragments, media["length"]) do
      :ok
    else
      {:error, :invalid_manifest}
    end
  end

  defp validate(_), do: {:error, :invalid_manifest}

  defp object(metadata, receipt) when is_map(metadata) and is_map(receipt) do
    %{
      "key" => nil,
      "length" => metadata["length"],
      "sha256" => metadata["sha256"],
      "etag" => Map.get(receipt, :etag),
      "version_id" => Map.get(receipt, :version_id)
    }
  end

  defp object(_, _), do: nil

  defp fragment(entry) when is_map(entry) do
    entry
    |> Map.take(@fragment_keys)
    |> Map.put("tail_duration_source", Map.get(entry, "tail_duration_source"))
    |> Map.put("motion", "unknown")
  end

  defp fragment(_), do: nil

  defp put_object_keys(manifest) do
    identity = manifest["identity"]
    tuple = Enum.map(~w(source_id profile recorder_epoch block_sequence), &identity[&1])
    block_id = :sha256 |> :crypto.hash(Jason.encode!(tuple)) |> Base.encode16(case: :lower)
    prefix = "recordings/v1/" <> block_id

    manifest
    |> put_in(["init", "key"], prefix <> "/init.mp4")
    |> put_in(["media", "key"], prefix <> "/media.m4s")
  end

  defp valid_identity?(identity) when is_map(identity) do
    Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys) and
      text?(identity["source_id"], 128) and text?(identity["profile"], 128) and
      integer?(identity["recorder_epoch"], 1, @max_integer) and
      integer?(identity["block_sequence"], 0, @max_integer) and valid_clock?(identity["clock"])
  end

  defp valid_identity?(_), do: false

  defp valid_clock?(
         %{"clock_epoch" => epoch, "timebase" => timebase, "dts_source" => "pts_no_reordering", "utc_mapping" => mapping} =
           clock
       ) do
    map_size(clock) == 4 and text?(epoch, 128) and integer?(timebase, 1, 1_000_000_000) and
      valid_mapping?(mapping, timebase)
  end

  defp valid_clock?(_), do: false
  defp valid_mapping?("unknown", _timebase), do: true

  defp valid_mapping?(
         %{"origin_media_ticks" => media, "origin_utc_usec" => utc, "uncertainty_usec" => uncertainty} = mapping,
         timebase
       ) do
    map_size(mapping) == 3 and integer?(media, 0, @max_integer) and
      div(media * 1_000_000_000, timebase) <= @max_integer and
      integer?(utc, -@max_integer, @max_integer) and integer?(uncertainty, 0, @max_integer)
  end

  defp valid_mapping?(_, _), do: false

  defp codec(%{avc1: %{profile: 66, compatibility: compatibility, level: level} = avc} = codecs)
       when map_size(codecs) == 1 and map_size(avc) == 3 and compatibility in 0..255 and level in 0..255 do
    hex = Base.encode16(<<66, compatibility, level>>, case: :lower)
    {:ok, "avc1." <> hex}
  end

  defp codec(_), do: {:error, :unsupported_codec}

  defp valid_format?(%{"codec" => codec, "timescale" => timescale} = format) do
    map_size(format) == 2 and is_binary(codec) and Regex.match?(~r/\Aavc1\.42[0-9a-f]{4}\z/, codec) and
      integer?(timescale, 1, 1_000_000_000)
  end

  defp valid_format?(_), do: false

  defp valid_object?(
         %{"key" => key, "length" => size, "sha256" => hash, "etag" => etag, "version_id" => version} = object,
         limit
       ) do
    map_size(object) == 5 and (is_nil(key) or text?(key, 128)) and integer?(size, 1, limit) and sha256?(hash) and
      valid_receipt?(etag, version)
  end

  defp valid_object?(_, _), do: false

  defp valid_receipt?(etag, version) do
    (is_nil(etag) or strong_etag?(etag)) and
      (is_nil(version) or (version != "null" and text?(version, 1024))) and
      (not is_nil(etag) or not is_nil(version))
  end

  defp valid_fragments?(fragments, size) when is_list(fragments) and length(fragments) in 1..4096 do
    fragments
    |> Enum.reduce_while({0, 0, nil}, fn fragment, position ->
      case next_fragment(fragment, position) do
        {:ok, next} -> {:cont, next}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {_sequence, ^size, _end_ns} -> true
      _ -> false
    end
  end

  defp valid_fragments?(_, _), do: false

  defp next_fragment(
         %{
           "sequence" => sequence,
           "offset" => offset,
           "length" => size,
           "start_ns" => start,
           "duration_ns" => duration,
           "sha256" => hash,
           "tail_duration_source" => source,
           "motion" => "unknown"
         } = fragment,
         {sequence, offset, previous_end}
       ) do
    if map_size(fragment) == 8 and integer?(size, 1, 33_554_432) and
         valid_interval?(start, duration, previous_end) and
         sha256?(hash) and source in [nil, "previous_sample"] do
      {:ok, {sequence + 1, offset + size, start + duration}}
    else
      :error
    end
  end

  defp next_fragment(_, _), do: :error

  defp valid_interval?(start, duration, previous_end) do
    integer?(start, 0, @max_integer) and integer?(duration, 1, 60_000_000_000) and
      start + duration <= @max_integer and (is_nil(previous_end) or start == previous_end)
  end

  defp strong_etag?(value),
    do: is_binary(value) and byte_size(value) <= 258 and Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, value)

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp integer?(value, first, last), do: is_integer(value) and value >= first and value <= last

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and String.printable?(value)

  defp text?(_, _), do: false

  defp canonical(value) when is_map(value) do
    value |> Enum.sort() |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
