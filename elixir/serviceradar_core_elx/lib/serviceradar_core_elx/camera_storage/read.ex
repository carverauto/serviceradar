defmodule ServiceRadarCoreElx.CameraStorage.Read do
  @moduledoc false

  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP

  @fields ~w(schema_version binding_id destination_sha256 descriptor_sha256 manifest_verification_sha256 block_id object_key first last size etag version_id sha256)

  def run(config, plan, deadline) do
    with true <- valid?(config, plan),
         remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond) do
      fetch(config.provider, plan, remaining)
    else
      _ -> {:error, :invalid_archive_range}
    end
  end

  defp fetch(provider, plan, timeout) do
    url = provider.destination["endpoint"] <> "/" <> provider.destination["bucket"] <> "/" <> plan["object_key"]
    url = if plan["version_id"], do: url <> "?versionId=" <> URI.encode_www_form(plan["version_id"]), else: url
    headers = [{"range", "bytes=#{plan["first"]}-#{plan["last"]}"}, {"if-match", plan["etag"]}]
    signed = HTTP.sign(provider, :get, url, headers, nil)
    size = plan["last"] - plan["first"] + 1
    interval = {plan["first"], plan["last"], plan["size"], plan["etag"], plan["version_id"]}

    with {:ok, %{status: 206, body: bytes}} <- HTTP.request(provider, :get, url, signed, nil, timeout, size, interval),
         true <- byte_size(bytes) == size,
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == plan["sha256"] do
      {:ok, bytes}
    else
      _ -> {:error, :archive_read_unavailable}
    end
  end

  defp valid?(config, plan) when is_map(plan) do
    Enum.sort(Map.keys(plan)) == Enum.sort(@fields) and plan["schema_version"] === 1 and
      identity?(config, plan) and key?(plan["object_key"]) and
      interval?(plan) and etag?(plan["etag"]) and version?(plan["version_id"])
  end

  defp valid?(_, _), do: false

  defp identity?(config, plan) do
    plan["binding_id"] == config.binding_id and plan["destination_sha256"] == config.destination_sha256 and
      Enum.all?(~w(destination_sha256 descriptor_sha256 manifest_verification_sha256 sha256), &sha?(plan[&1])) and
      uuid?(plan["binding_id"]) and uuid?(plan["block_id"])
  end

  defp interval?(%{"first" => first, "last" => last, "size" => size, "object_key" => key}) do
    Enum.all?([first, last, size], &is_integer/1) and first >= 0 and first <= last and
      last < size and size <= 16_777_216 and payload_interval?(key, first, last, size)
  end

  defp payload_interval?(key, first, last, size) do
    if String.ends_with?(key, "/init.mp4") do
      first == 0 and last == size - 1 and size <= 1_048_576
    else
      last - first + 1 <= 4_194_304
    end
  end

  defp key?(value),
    do: is_binary(value) and Regex.match?(~r/\Arecordings\/v1\/[0-9a-f]{64}\/(?:init\.mp4|media\.m4s)\z/, value)

  defp uuid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp etag?(value),
    do: is_binary(value) and byte_size(value) in 3..256 and Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, value)

  defp version?(nil), do: true

  defp version?(value),
    do: is_binary(value) and byte_size(value) in 1..1024 and value != "null" and Regex.match?(~r/\A[\x21-\x7e]+\z/, value)
end
