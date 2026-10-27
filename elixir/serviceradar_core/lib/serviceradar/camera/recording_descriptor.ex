defmodule ServiceRadar.Camera.RecordingDescriptor do
  @moduledoc """
  Receipt-free, bounded semantic description of one sealed camera block.

  This is shared by the retained CNPG block and the archive manifest. Validation
  binds identity, clock, native init/codec configuration and complete fragment
  ranges; it does not verify media bytes or grant archive availability. The
  recorder supplies a verified Spool snapshot and its actual native init format.
  """
  @max_json_bytes 2_097_152
  @max_integer 9_223_372_036_854_775_807
  @identity_keys ~w(source_id profile recorder_epoch block_sequence clock)
  @fragment_keys ~w(sequence offset length start_ns duration_ns sha256 tail_duration_source motion)

  def from_snapshot(
        %{
          sealed?: true,
          identity: identity,
          init: init,
          entries: entries,
          high_water: size,
          sha256: sha
        },
        %{
          sha256: init_sha,
          timescale: timescale,
          codecs: codecs
        }
      ) do
    with true <- is_map(init) and init["sha256"] == init_sha,
         {:ok, codec} <- codec(codecs),
         true <- is_list(entries) and length(entries) in 1..4096 do
      descriptor = %{
        "version" => 1,
        "identity" => identity,
        "format" => %{"codec" => codec, "timescale" => timescale},
        "init" => Map.take(init, ~w(length sha256)),
        "media" => %{"length" => size, "sha256" => sha},
        "fragments" => Enum.map(entries, &fragment/1)
      }

      with :ok <- validate(descriptor), do: {:ok, descriptor}
    else
      _ -> {:error, :invalid_recording_descriptor}
    end
  end

  def from_snapshot(_, _), do: {:error, :invalid_recording_descriptor}

  def encode(descriptor) do
    with :ok <- validate(descriptor),
         {:ok, bytes} <- Jason.encode(canonical(descriptor)),
         true <- byte_size(bytes) <= @max_json_bytes do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_recording_descriptor}
    end
  end

  def validate(
        %{
          "version" => 1,
          "identity" => identity,
          "format" => format,
          "init" => init,
          "media" => media,
          "fragments" => fragments
        } = descriptor
      ) do
    if map_size(descriptor) == 6 and valid_identity?(identity) and valid_format?(format) and
         valid_object?(init, 1_048_576) and valid_object?(media, 536_870_912) and
         valid_fragments?(fragments, media["length"]),
       do: :ok,
       else: {:error, :invalid_recording_descriptor}
  end

  def validate(_), do: {:error, :invalid_recording_descriptor}

  @doc "Stable key from an already validated identity; clock/content cannot select another key."
  def block_key(identity) do
    tuple = Enum.map(~w(source_id profile recorder_epoch block_sequence), &identity[&1])
    :sha256 |> :crypto.hash(Jason.encode!(tuple)) |> Base.encode16(case: :lower)
  end

  @doc "Object key from a validated identity; shared by upload intent and recovery manifests."
  def object_key(identity, role) when role in [:init, :media, :manifest] do
    filename = %{init: "init.mp4", media: "media.m4s", manifest: "manifest.json"}[role]
    "recordings/v1/" <> block_key(identity) <> "/" <> filename
  end

  defp valid_object?(%{"length" => size, "sha256" => hash} = object, limit),
    do: map_size(object) == 2 and integer?(size, 1, limit) and sha256?(hash)

  defp valid_object?(_, _), do: false

  defp fragment(entry) when is_map(entry) do
    entry
    |> Map.take(@fragment_keys)
    |> Map.put("tail_duration_source", Map.get(entry, "tail_duration_source"))
    |> Map.put("motion", "unknown")
  end

  defp fragment(_), do: nil

  def valid_identity?(identity) when is_map(identity) do
    Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys) and
      text?(identity["source_id"], 128) and text?(identity["profile"], 128) and
      integer?(identity["recorder_epoch"], 1, @max_integer) and
      integer?(identity["block_sequence"], 0, @max_integer) and valid_clock?(identity["clock"])
  end

  def valid_identity?(_), do: false

  defp valid_clock?(
         %{
           "clock_epoch" => epoch,
           "timebase" => timebase,
           "dts_source" => "pts_no_reordering",
           "utc_mapping" => mapping
         } =
           clock
       ) do
    map_size(clock) == 4 and text?(epoch, 128) and integer?(timebase, 1, 1_000_000_000) and
      valid_mapping?(mapping, timebase)
  end

  defp valid_clock?(_), do: false
  defp valid_mapping?("unknown", _timebase), do: true

  defp valid_mapping?(
         %{
           "origin_media_ticks" => media,
           "origin_utc_usec" => utc,
           "uncertainty_usec" => uncertainty
         } = mapping,
         timebase
       ) do
    map_size(mapping) == 3 and integer?(media, 0, @max_integer) and
      div(media * 1_000_000_000, timebase) <= @max_integer and
      integer?(utc, -@max_integer, @max_integer) and integer?(uncertainty, 0, @max_integer)
  end

  defp valid_mapping?(_, _), do: false

  defp codec(%{avc1: %{profile: 66, compatibility: compatibility, level: level} = avc} = codecs)
       when map_size(codecs) == 1 and map_size(avc) == 3 and compatibility in 0..255 and
              level in 0..255 do
    hex = Base.encode16(<<66, compatibility, level>>, case: :lower)
    {:ok, "avc1." <> hex}
  end

  defp codec(_), do: {:error, :unsupported_codec}

  defp valid_format?(%{"codec" => codec, "timescale" => timescale} = format) do
    map_size(format) == 2 and is_binary(codec) and
      Regex.match?(~r/\Aavc1\.42[0-9a-f]{4}\z/, codec) and
      integer?(timescale, 1, 1_000_000_000)
  end

  defp valid_format?(_), do: false

  defp valid_fragments?(fragments, size)
       when is_list(fragments) and length(fragments) in 1..4096 do
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

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp integer?(value, first, last), do: is_integer(value) and value >= first and value <= last

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and String.printable?(value)

  defp text?(_, _), do: false

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
