defmodule ServiceRadarWebNG.CameraTimelineReader.Archive do
  @moduledoc """
  Archive-copy reader for timeline playback (`D.2`, `design.md` `D6`,
  `spec.md` "Isolated archive reads with inventory credentials").

  Forwards a single exact read plan (`destination`, reader-role `credential`,
  and byte-range `plan`) over mTLS + bearer auth to the isolated archive reader's
  `POST /v1/timeline-archive-ranges` endpoint within `deadline_ms`.

  Credentials are never logged, persisted, or returned in errors.
  """

  @behaviour ServiceRadarWebNG.CameraTimelineReader

  alias ServiceRadar.Camera.ArchiveStorageConfig
  alias ServiceRadar.Camera.ArchiveStorageHTTP
  alias ServiceRadar.Camera.RecordingTimeline.RedactedCredential
  alias ServiceRadarWebNG.CameraTimelineReader

  require Logger

  @min_response_buffer_bytes 4_096

  @impl true
  defdelegate fetch_local(plan, deadline_ms), to: CameraTimelineReader

  @impl true
  def fetch_archive(plan, deadline_ms) when is_map(plan) and is_integer(deadline_ms) do
    cond do
      not is_nil(Map.get(plan, :credential_error)) ->
        log_failure(plan, :credential_error)
        {:error, :reader_unavailable}

      is_nil(Map.get(plan, :credential)) ->
        log_failure(plan, :missing_credential)
        {:error, :reader_unavailable}

      true ->
        execute_fetch(plan, deadline_ms)
    end
  end

  def fetch_archive(_plan, _deadline_ms), do: {:error, :reader_unavailable}

  defp execute_fetch(plan, deadline_ms) do
    with {:ok, config_path} <- config_path(),
         {:ok, %{client: client}} <- ArchiveStorageConfig.load_timeline_reader(config_path),
         {:ok, credential_map} <- extract_credential(Map.get(plan, :credential)),
         {:ok, payload} <- build_request_payload(plan, credential_map),
         {:ok, remaining} <- remaining_ms(deadline_ms) do
      body = Jason.encode!(payload)

      headers = [
        {"authorization", "Bearer " <> client.token},
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]

      max_bytes = max(Map.get(plan, :expected_length, 0), @min_response_buffer_bytes)
      url = client.base_url <> "/v1/timeline-archive-ranges"

      result =
        ArchiveStorageHTTP.request(client, :post, url, headers, body, remaining, max_bytes)

      handle_response(result, plan)
    else
      {:error, reason} ->
        log_failure(plan, reason)
        {:error, :reader_unavailable}
    end
  end

  defp handle_response({:ok, %{status: 200, body: bytes}}, plan) when is_binary(bytes) do
    if valid_digest_and_length?(bytes, plan) do
      {:ok, bytes}
    else
      log_failure(plan, :integrity_mismatch)
      {:error, :integrity_mismatch}
    end
  end

  defp handle_response({:ok, %{status: 404}}, _plan), do: {:error, :not_found}

  defp handle_response({:ok, %{status: 409}}, plan) do
    log_failure(plan, :integrity_mismatch)
    {:error, :integrity_mismatch}
  end

  defp handle_response({:ok, %{status: status}}, plan) do
    log_failure(plan, {:reader_status, status})
    {:error, :reader_unavailable}
  end

  defp handle_response({:error, reason}, plan) do
    log_failure(plan, reason)
    {:error, :reader_unavailable}
  end

  defp handle_response(_other, plan) do
    log_failure(plan, :unexpected_response)
    {:error, :reader_unavailable}
  end

  defp config_path do
    case Application.get_env(:serviceradar_web_ng, :timeline_archive_reader_config) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :timeline_archive_reader_not_configured}
    end
  end

  defp remaining_ms(deadline_ms) do
    case deadline_ms - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _ -> {:error, :timeout}
    end
  end

  defp extract_credential(%RedactedCredential{} = cred) do
    build_credential_map(cred.access_key_id, cred.secret_access_key, cred.session_token)
  end

  defp extract_credential(_), do: {:error, :invalid_credential}

  defp build_credential_map(access_key, secret_key, session_token)
       when is_binary(access_key) and access_key != "" and is_binary(secret_key) and secret_key != "" do
    base = %{"access_key_id" => access_key, "secret_access_key" => secret_key}

    map =
      if is_binary(session_token) and session_token != "" do
        Map.put(base, "session_token", session_token)
      else
        base
      end

    {:ok, map}
  end

  defp build_credential_map(_, _, _), do: {:error, :invalid_credential}

  defp build_request_payload(plan, credential_map) do
    destination = Map.get(plan, :destination)
    storage_id = Map.get(plan, :storage_id)
    block_key = Map.get(plan, :block_key)
    object_key = Map.get(plan, :object_key)
    first = Map.get(plan, :first)
    last = Map.get(plan, :last)
    size = Map.get(plan, :object_size)
    etag = Map.get(plan, :etag)
    version_id = Map.get(plan, :version_id)
    sha256 = Map.get(plan, :expected_sha256)

    if is_map(destination) and not is_nil(storage_id) and not is_nil(block_key) and
         is_binary(object_key) and is_integer(first) and is_integer(last) and
         is_integer(size) and is_binary(etag) and is_binary(sha256) do
      {:ok,
       %{
         "schema_version" => 1,
         "destination" => destination,
         "credential" => credential_map,
         "plan" => %{
           "storage_id" => to_string(storage_id),
           "block_key" => to_string(block_key),
           "object_key" => object_key,
           "first" => first,
           "last" => last,
           "size" => size,
           "etag" => etag,
           "version_id" => version_id,
           "sha256" => sha256
         }
       }}
    else
      {:error, :invalid_archive_plan}
    end
  end

  defp valid_digest_and_length?(bytes, plan) do
    expected_len = Map.get(plan, :expected_length)
    expected_sha = Map.get(plan, :expected_sha256)

    is_integer(expected_len) and
      byte_size(bytes) == expected_len and
      is_binary(expected_sha) and
      :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == expected_sha
  end

  defp log_failure(plan, reason) do
    Logger.warning(
      "Timeline archive read failed entry_id=#{Map.get(plan, :entry_id)} storage_id=#{Map.get(plan, :storage_id)} reason=#{inspect(reason, limit: 8)}"
    )
  end
end
