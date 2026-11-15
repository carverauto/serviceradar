defmodule ServiceRadarCoreElx.CameraRecording.NVRArchive do
  @moduledoc """
  Asks one installed NVR member to copy one sealed local block to an archive bucket.

  The destination comes from an `ArchiveBinding`. Its `s3_compatible` writer
  credential is resolved through `ArchiveCredentialResolver`, whose broker grant is
  locked to the binding's HTTPS host, bucket and `namespace` prefix. The request
  carries that destination with the namespace as `object_prefix`, the member's
  provisioned `storage_id` and this deployment's recovery generation over the
  member's pinned mTLS and bearer channel.

  No media passes through Core, so this runs on any core node. Recording must be
  enabled and the recovery gate ready before the credential is resolved, and the
  gate is checked again before success is returned. The credential exists only
  for the call: it is never logged, returned, raised or stored. The receipt is
  local dual-write evidence, not catalog, playback or reclamation authority.
  An `:outcome_unknown` result is not retried here; repeating the request is
  safe because the NVR returns an existing receipt and never overwrites objects.
  """

  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarRecordingControl.RecoveryGate

  @block_id_pattern ~r/\A[0-9a-f]{64}\z/
  @default_timeout_ms 120_000
  @max_timeout_ms 300_000
  @destination_fields ~w(
    schema_version provisioning_ref generation purpose provider endpoint region
    bucket namespace archive_format_version required_encryption
  )a
  @destination_defaults %{schema_version: 1, archive_format_version: 1}

  @spec archive_block(String.t(), String.t(), map() | struct(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def archive_block(member, block_id, binding, secret_id, opts \\ [])

  def archive_block(member, block_id, binding, secret_id, opts) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    with true <- valid_block_id?(block_id) || {:error, :invalid_block_id},
         true <- timeout_ms in 1..@max_timeout_ms || {:error, :invalid_archive_timeout},
         {:ok, target} <- NVRTargetConfig.resolve(member, opts),
         true <- RecordingSupervisor.enabled?() || {:error, :recording_disabled},
         {:ok, destination} <- destination(binding) do
      archive = %{target: target, block_id: block_id, destination: destination, timeout_ms: timeout_ms}

      RecoveryGate.with_ready(gate, fn ->
        send_archive(archive, gate.generation, writer_credential(binding, secret_id, opts))
      end)
    end
  end

  def archive_block(_member, _block_id, _binding, _secret_id, _opts), do: {:error, :invalid_archive_request}

  defp send_archive(archive, recovery_generation, {:ok, credential}) do
    request = %{
      "version" => 1,
      "storage_id" => archive.target.storage_id,
      "recovery_generation" => recovery_generation,
      "destination" => archive.destination,
      "credential" => credential
    }

    ServiceRadarNVRClient.archive_block(archive.target.client_config, archive.block_id, request, archive.timeout_ms)
  end

  defp send_archive(_archive, _recovery_generation, {:error, _reason} = error), do: error

  # Only the two key fields leave this function. Errors are reduced to their
  # atom tag so that no part of a resolver or broker term reaches the caller.
  defp writer_credential(binding, secret_id, opts) do
    case ArchiveCredentialResolver.resolve_for_binding(binding, :writer, secret_id, opts) do
      {:ok, %{"access_key_id" => access_key_id, "secret_access_key" => secret_access_key}} ->
        {:ok, %{"access_key_id" => access_key_id, "secret_access_key" => secret_access_key}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:archive_credential_unavailable, reason}}

      {:error, {reason, _detail}} when is_atom(reason) ->
        {:error, {:archive_credential_unavailable, reason}}

      _ ->
        {:error, {:archive_credential_unavailable, :credential_resolution_failed}}
    end
  end

  # Builds the same destination input `ArchiveCredentialResolver` validates, so
  # the request names exactly the host, bucket and prefix its grant covers.
  defp destination(binding) when is_map(binding) do
    input =
      Map.new(@destination_fields, fn name ->
        {Atom.to_string(name), field(binding, name) || Map.get(@destination_defaults, name)}
      end)

    case ArchiveDestination.attributes(input) do
      {:ok, %{endpoint: endpoint, region: region, bucket: bucket, namespace: namespace}} ->
        {:ok,
         %{
           "host" => URI.parse(endpoint).host,
           "region" => region,
           "bucket" => bucket,
           "object_prefix" => namespace
         }}

      {:error, _reason} ->
        {:error, :invalid_archive_binding}
    end
  end

  defp destination(_binding), do: {:error, :invalid_archive_binding}

  defp valid_block_id?(block_id), do: is_binary(block_id) and Regex.match?(@block_id_pattern, block_id)

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
