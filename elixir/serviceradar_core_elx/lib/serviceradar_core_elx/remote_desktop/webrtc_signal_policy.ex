defmodule ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalPolicy do
  @moduledoc """
  Server-side policy checks for remote desktop WebRTC signaling.

  Browser-side checks are useful for fast feedback, but the server is the trust
  boundary for SDP answers and ICE candidates before they reach ExWebRTC.
  """

  import Bitwise, only: [&&&: 2, >>>: 2]

  @allowed_media_types MapSet.new(["application", "video"])
  @allowed_video_codecs MapSet.new([
                          "h264",
                          "vp8",
                          "vp9",
                          "vp09",
                          "av1",
                          "av01",
                          "rtx",
                          "red",
                          "ulpfec",
                          "flexfec-03"
                        ])
  @primary_video_codecs MapSet.new(["h264", "vp8", "vp9", "vp09", "av1", "av01"])
  @allowed_fingerprint_algorithms MapSet.new(["sha-256", "sha-384", "sha-512"])

  @type reason ::
          :invalid_sdp
          | :missing_media_section
          | :duplicate_media_section
          | :unsupported_media_type
          | :unsupported_video_codec
          | :missing_video_codec
          | :missing_dtls_fingerprint
          | :unsupported_dtls_fingerprint
          | :invalid_ice_candidate
          | :blocked_ice_candidate

  @spec validate_answer_sdp(binary()) :: :ok | {:error, reason()}
  def validate_answer_sdp(sdp) when is_binary(sdp) do
    lines = sdp_lines(sdp)

    with true <- lines != [] || {:error, :invalid_sdp},
         {:ok, sections} <- media_sections(lines),
         :ok <- validate_media_sections(sections),
         :ok <- validate_fingerprints(lines) do
      validate_embedded_ice_candidates(lines)
    end
  end

  def validate_answer_sdp(_sdp), do: {:error, :invalid_sdp}

  @spec validate_ice_candidate(term()) :: :ok | {:error, reason()}
  def validate_ice_candidate(candidate) do
    with {:ok, candidate_line} <- extract_candidate_line(candidate),
         {:ok, address} <- candidate_address(candidate_line) do
      validate_candidate_address(address)
    end
  end

  defp sdp_lines(sdp) do
    sdp
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp media_sections(lines) do
    sections =
      lines
      |> Enum.reduce({[], nil}, fn line, {sections, current} ->
        cond do
          String.starts_with?(line, "m=") ->
            {push_section(sections, current), %{media_type: media_type(line), lines: [line]}}

          is_map(current) ->
            {sections, %{current | lines: [line | current.lines]}}

          true ->
            {sections, current}
        end
      end)
      |> then(fn {sections, current} -> push_section(sections, current) end)
      |> Enum.reverse()
      |> Enum.map(fn section -> %{section | lines: Enum.reverse(section.lines)} end)

    case sections do
      [] -> {:error, :missing_media_section}
      _sections -> {:ok, sections}
    end
  end

  defp push_section(sections, nil), do: sections
  defp push_section(sections, section), do: [section | sections]

  defp media_type("m=" <> rest) do
    rest
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
    |> to_string()
    |> String.downcase()
  end

  defp validate_media_sections(sections) do
    media_types = Enum.map(sections, & &1.media_type)

    with :ok <- validate_allowed_media_types(media_types),
         :ok <- validate_unique_media_types(media_types) do
      validate_all_media_sections(sections)
    end
  end

  defp validate_allowed_media_types(media_types) do
    if Enum.any?(media_types, &(not MapSet.member?(@allowed_media_types, &1))) do
      {:error, :unsupported_media_type}
    else
      :ok
    end
  end

  defp validate_unique_media_types(media_types) do
    if length(media_types) == length(Enum.uniq(media_types)) do
      :ok
    else
      {:error, :duplicate_media_section}
    end
  end

  defp validate_all_media_sections(sections) do
    Enum.reduce_while(sections, :ok, fn section, :ok ->
      case validate_media_section(section) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_media_section(%{media_type: "application"}), do: :ok

  defp validate_media_section(%{media_type: "video", lines: lines}) do
    codecs =
      lines
      |> Enum.filter(&String.starts_with?(&1, "a=rtpmap:"))
      |> Enum.map(&rtpmap_codec/1)
      |> Enum.reject(&is_nil/1)

    cond do
      codecs == [] ->
        {:error, :missing_video_codec}

      Enum.any?(codecs, &(not MapSet.member?(@allowed_video_codecs, &1))) ->
        {:error, :unsupported_video_codec}

      Enum.any?(codecs, &MapSet.member?(@primary_video_codecs, &1)) ->
        :ok

      true ->
        {:error, :missing_video_codec}
    end
  end

  defp validate_media_section(_section), do: {:error, :unsupported_media_type}

  defp rtpmap_codec("a=rtpmap:" <> rest) do
    rest
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> case do
      [_payload_type, encoding] ->
        encoding
        |> String.split("/", parts: 2)
        |> List.first()
        |> String.downcase()

      _other ->
        nil
    end
  end

  defp validate_fingerprints(lines) do
    algorithms =
      lines
      |> Enum.filter(&String.starts_with?(&1, "a=fingerprint:"))
      |> Enum.map(&fingerprint_algorithm/1)
      |> Enum.reject(&is_nil/1)

    cond do
      algorithms == [] ->
        {:error, :missing_dtls_fingerprint}

      Enum.all?(algorithms, &MapSet.member?(@allowed_fingerprint_algorithms, &1)) ->
        :ok

      true ->
        {:error, :unsupported_dtls_fingerprint}
    end
  end

  defp fingerprint_algorithm("a=fingerprint:" <> rest) do
    rest
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
    |> case do
      nil -> nil
      algorithm -> String.downcase(algorithm)
    end
  end

  defp validate_embedded_ice_candidates(lines) do
    lines
    |> Enum.filter(&String.starts_with?(&1, "a=candidate:"))
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case validate_ice_candidate(candidate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp extract_candidate_line(%{candidate: candidate}) when is_binary(candidate), do: {:ok, candidate}
  defp extract_candidate_line(%{"candidate" => candidate}) when is_binary(candidate), do: {:ok, candidate}
  defp extract_candidate_line(candidate) when is_binary(candidate), do: {:ok, candidate}
  defp extract_candidate_line(_candidate), do: {:error, :invalid_ice_candidate}

  defp candidate_address(candidate_line) do
    candidate_line =
      candidate_line
      |> String.trim()
      |> String.trim_leading("a=")

    parts = String.split(candidate_line, ~r/\s+/, trim: true)

    with true <- length(parts) >= 6,
         "candidate:" <> _foundation <- Enum.at(parts, 0),
         address when is_binary(address) <- Enum.at(parts, 4),
         false <- String.trim(address) == "" do
      {:ok, address}
    else
      _other -> {:error, :invalid_ice_candidate}
    end
  end

  defp validate_candidate_address(address) do
    with false <- local_candidate_address?(address),
         {:ok, tuple} <- :inet.parse_address(String.to_charlist(address)),
         false <- blocked_ip_tuple?(tuple) do
      :ok
    else
      true -> {:error, :blocked_ice_candidate}
      {:error, _reason} -> {:error, :invalid_ice_candidate}
    end
  end

  defp local_candidate_address?(address), do: address |> String.downcase() |> String.ends_with?(".local")

  defp blocked_ip_tuple?({127, _b, _c, _d}), do: true
  defp blocked_ip_tuple?({10, _b, _c, _d}), do: true
  defp blocked_ip_tuple?({172, b, _c, _d}) when b in 16..31, do: true
  defp blocked_ip_tuple?({192, 168, _c, _d}), do: true
  defp blocked_ip_tuple?({169, 254, _c, _d}), do: true
  defp blocked_ip_tuple?({100, b, _c, _d}) when b in 64..127, do: true
  defp blocked_ip_tuple?({a, _b, _c, _d}) when a in 224..255, do: true
  defp blocked_ip_tuple?({0, _b, _c, _d}), do: true
  defp blocked_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_ip_tuple?({0, 0, 0, 0, 0, 65_535, high, low}), do: blocked_ip_tuple?(ipv4_mapped(high, low))
  defp blocked_ip_tuple?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFC00..0xFDFF, do: true
  defp blocked_ip_tuple?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFE80..0xFEBF, do: true
  defp blocked_ip_tuple?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFF00..0xFFFF, do: true
  defp blocked_ip_tuple?(_tuple), do: false

  defp ipv4_mapped(high, low) do
    {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
  end
end
