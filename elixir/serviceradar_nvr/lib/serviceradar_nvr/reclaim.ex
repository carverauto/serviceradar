defmodule ServiceRadarNVR.Reclaim do
  @moduledoc """
  Authenticated local block reclaim (`POST /v1/blocks/<block_id>/reclaim`).

  Each reclaim is bound to this member's storage UUID, boot-pinned recovery
  generation, a Core operation UUID and the expected canonical descriptor
  SHA-256 of the sealed block. The NVR verifies the block, appends and fsyncs
  a tombstone to `.disposition-journal`, unlinks the block directory and updates
  the capacity ledger immediately. Exact retries return the same receipt.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarNVR.Capacity
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @request_timeout_ms 30_000

  def request_timeout_ms, do: @request_timeout_ms

  @doc "Validate and execute one reclaim request; returns the HTTP status and response body."
  def run(config, block_id, body) do
    result =
      with {:ok, request} <- parse(config, block_id, body),
           :ok <- ready(config.recovery_gate) do
        Capacity.reclaim_block(block_id, request)
      end

    response(result)
  end

  defp parse(config, block_id, body) do
    if Blocks.valid_id?(block_id),
      do: decode(config, body),
      else: {:error, :block_not_found}
  end

  defp decode(config, body) do
    with {:ok,
          %{
            "version" => 1,
            "storage_id" => storage_id,
            "recovery_generation" => generation,
            "operation_id" => operation_id,
            "expected_descriptor_sha256" => digest
          } = document}
         when map_size(document) == 5 <- Jason.decode(body),
         {:ok, ^body} <- CanonicalJSON.encode(document),
         true <- is_binary(storage_id) and storage_id == config.storage_id,
         true <- generation?(config.recovery_gate, generation),
         true <- canonical_uuid?(operation_id) and Blocks.valid_id?(digest) do
      {:ok, %{operation_id: operation_id, expected_descriptor_sha256: digest}}
    else
      _ -> {:error, :invalid_reclaim_request}
    end
  end

  defp generation?(%{generation: generation}, value), do: is_binary(value) and value == generation
  defp generation?(_gate, _value), do: false

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_value), do: false

  defp ready(gate) do
    case RecoveryGate.check(gate) do
      :ok -> :ok
      _ -> {:error, :reclaim_unavailable}
    end
  end

  defp response({:ok, receipt}) do
    case CanonicalJSON.encode(receipt) do
      {:ok, bytes} -> {200, bytes}
      _ -> {503, %{error: "reclaim_unavailable"}}
    end
  end

  defp response({:error, :invalid_reclaim_request}), do: {400, %{error: "invalid_reclaim_request"}}
  defp response({:error, :block_not_found}), do: {404, %{error: "block_not_found"}}
  defp response({:error, :descriptor_mismatch}), do: {409, %{error: "descriptor_mismatch"}}
  defp response({:error, :block_not_sealed}), do: {409, %{error: "block_not_sealed"}}
  defp response({:error, :block_active}), do: {409, %{error: "block_active"}}
  defp response({:error, :reclaim_conflict}), do: {409, %{error: "reclaim_conflict"}}
  defp response({:error, _reason}), do: {503, %{error: "reclaim_unavailable"}}
end
