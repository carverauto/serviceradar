defmodule ServiceRadar.Camera.RelaySourceFailure do
  @moduledoc """
  The agent's classified account of why a camera source failed to start or
  stopped delivering media.

  The agent reports it as `CloseRelaySessionRequest.failure_reason`, formatted
  `"<class>"` or `"<class>: <detail>"`; the class set is owned by the agent
  (`go/pkg/agent/camera_relay_failure.go`). The agent strips URLs, userinfo and
  query strings at the source, but this is edge input, so `normalize/1` checks
  the shape and sanitizes the detail again before it is stored, with
  `ServiceRadar.Credentials.SecretTextScrubber` (a URL keeps only its origin)
  plus the camera-specific path rules below. RTSP URLs carry
  usernames, passwords and alias tokens; none of them may reach the database.

  `describe/1` turns a stored reason into the sentence an operator reads next to
  the camera.
  """

  alias ServiceRadar.Credentials.SecretTextScrubber

  # A conforming agent sends at most a 48-byte class, ": " and a 200-byte detail.
  @max_reason_bytes 512
  @max_detail_bytes 200
  @class_pattern ~r/\A[a-z][a-z0-9_]{0,47}\z/

  # On top of SecretTextScrubber: a stream alias can also appear as a bare
  # host/path or a path alone in a camera error, so those are dropped too.
  @host_path_pattern ~r/([A-Za-z0-9\-\]]+(?:\.[A-Za-z0-9\-]+)*(?::\d+)?)\/[^\s"'<>)]*/
  @path_pattern ~r/(^|[\s"'(=:])\/(?!\/)[^\s"'<>)]*/

  @sentences %{
    "invalid_source_config" => "The camera's stream address is not a usable RTSP URL",
    "plugin_unavailable" =>
      "The camera plugin that provides this stream is not available on the agent",
    "dns_failure" => "The agent could not resolve the camera's host name",
    "connect_refused" => "The camera refused the connection",
    "connect_timeout" => "The agent timed out connecting to the camera",
    "host_unreachable" => "The agent has no network route to the camera",
    "connect_failed" => "The agent could not connect to the camera",
    "tls_certificate_invalid" => "The agent did not trust the camera's TLS certificate",
    "tls_handshake_failed" => "The TLS handshake with the camera failed",
    "authentication_failed" => "The camera refused the stream: authentication failed",
    "not_found" => "The camera has no stream at the requested path or alias",
    "rtsp_request_failed" => "The camera rejected the stream request",
    "response_timeout" =>
      "The camera accepted the connection but did not answer the stream request in time",
    "no_video_track" => "The camera's stream has no video track",
    "unsupported_codec" => "The camera's video codec is not supported; the relay requires H.264",
    "media_decode_failed" => "The agent could not decode the camera's video",
    "no_keyframe" => "The camera sent video but no usable H.264 keyframe",
    "read_timeout_no_media" => "The camera stopped sending video",
    "upstream_closed" => "The camera closed the connection",
    "start_deadline_exceeded" =>
      "The camera stream did not start before the agent's start deadline",
    "unknown" => "The camera stream failed"
  }

  @doc """
  Validates an agent-reported failure reason.

  Returns `{:ok, reason}` with the class kept and the detail sanitized and
  bounded, `:none` when nothing was reported, or `{:error, reason}` when the
  value is too large or its class is not a lower_snake_case identifier.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :none | {:error, :too_long | :invalid_class}
  def normalize(nil), do: :none

  def normalize(raw) when is_binary(raw) and byte_size(raw) > @max_reason_bytes,
    do: {:error, :too_long}

  def normalize(raw) when is_binary(raw) do
    # Control bytes and non-ASCII become spaces first, so a class carrying any
    # of them fails the identifier check instead of being silently repaired.
    {class, detail} = raw |> printable_ascii() |> split()

    cond do
      class == "" and detail == "" -> :none
      Regex.match?(@class_pattern, class) -> {:ok, format(class, sanitize_detail(detail))}
      true -> {:error, :invalid_class}
    end
  end

  def normalize(_raw), do: {:error, :invalid_class}

  @doc """
  The operator-facing sentence for a stored failure reason, with its detail in
  parentheses, or `nil` when the reason was not reported by an agent in this
  format (other writers store free-form text).
  """
  @spec describe(String.t() | nil) :: String.t() | nil
  def describe(reason) when is_binary(reason) do
    {class, detail} = split(reason)

    case {Map.fetch(@sentences, class), detail} do
      {{:ok, sentence}, ""} -> sentence <> "."
      {{:ok, sentence}, detail} -> "#{sentence} (#{detail})."
      {:error, _detail} -> nil
    end
  end

  def describe(_reason), do: nil

  defp split(value) do
    case String.split(value, ":", parts: 2) do
      [class, detail] -> {String.trim(class), String.trim(detail)}
      [class] -> {String.trim(class), ""}
    end
  end

  defp format(class, ""), do: class
  defp format(class, detail), do: class <> ": " <> detail

  defp sanitize_detail(detail) do
    detail
    |> SecretTextScrubber.scrub_text()
    |> String.replace(@host_path_pattern, "\\1")
    |> String.replace(@path_pattern, "\\1[path]")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@max_detail_bytes)
    |> String.trim()
  end

  defp printable_ascii(value), do: for(<<byte <- value>>, into: "", do: printable_byte(byte))

  defp printable_byte(byte) when byte in 0x20..0x7E, do: <<byte>>
  defp printable_byte(_byte), do: " "

  # Every byte is printable ASCII here, so a byte cut is a character cut.
  defp truncate(value, max) when byte_size(value) > max, do: binary_part(value, 0, max)
  defp truncate(value, _max), do: value
end
