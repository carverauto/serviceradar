defmodule ServiceRadarWebNG.CameraTimelineReader.NVRLocal do
  @moduledoc """
  Local-copy reader for timeline playback (design D5): reads a cataloged block's
  initialization bytes or one fragment from the NVR member that stores it, over
  that member's read listener.

  The member is the one whose provisioned storage UUID is the entry's
  `storage_id`, from web-ng's read-client configuration
  (`SERVICERADAR_NVR_READ_CLIENT_CONFIG_FILE` and
  `SERVICERADAR_NVR_READ_CLIENT_TOKEN_FILE`, format
  `ServiceRadarNVRClient.Members`): the read-purpose token and client
  certificate, never the ingest ones. Each request names the frozen
  descriptor's SHA-256 and the selected object's expected length and SHA-256 from
  the plan, and the client returns bytes only when they match.

  Results, for `ServiceRadarWebNG.CameraTimelineReader`: `{:ok, bytes}`,
  `{:error, :not_found}`, `{:error, :integrity_mismatch}` (the local copy is not
  the cataloged block), and otherwise an unavailable reason:
  `:nvr_read_not_configured`, `:invalid_nvr_client_config`,
  `:unknown_nvr_storage`, `:timeout`, `:unavailable` or a client status.
  """

  @behaviour ServiceRadarWebNG.CameraTimelineReader

  alias ServiceRadarNVRClient.Members
  alias ServiceRadarWebNG.CameraTimelineReader

  require Logger

  @impl true
  def fetch_local(plan, deadline_ms) do
    expected = %{length: plan.expected_length, sha256: plan.expected_sha256}

    result =
      with {:ok, config_file, token_file} <- client_files(),
           {:ok, members} <- Members.load(config_file, token_file),
           {:ok, target} <- Members.by_storage_id(members, to_string(plan.storage_id)),
           {:ok, timeout_ms} <- remaining_ms(deadline_ms) do
        ServiceRadarNVRClient.read_block(
          target.client_config,
          plan.block_key,
          plan.descriptor_sha256,
          plan.selector,
          expected,
          timeout_ms
        )
      end

    log_read_failure(result, plan.storage_id)
  end

  # Archive copies are read by the isolated archive reader (D.2), not by an NVR.
  @impl true
  defdelegate fetch_archive(plan, deadline_ms), to: CameraTimelineReader

  defp client_files do
    config = Application.get_env(:serviceradar_web_ng, :nvr_read_client, [])

    case {config[:config_file], config[:token_file]} do
      {config_file, token_file} when is_binary(config_file) and is_binary(token_file) ->
        {:ok, config_file, token_file}

      _ ->
        {:error, :nvr_read_not_configured}
    end
  end

  defp remaining_ms(deadline_ms) do
    case deadline_ms - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, min(remaining, 300_000)}
      _ -> {:error, :timeout}
    end
  end

  defp log_read_failure({:ok, _bytes} = result, _storage_id), do: result

  defp log_read_failure({:error, reason} = result, _storage_id) when reason in [:not_found, :integrity_mismatch] do
    result
  end

  defp log_read_failure({:error, reason} = result, storage_id) do
    Logger.warning("NVR local playback read failed storage_id=#{storage_id} reason=#{inspect(reason, limit: 8)}")
    result
  end
end
