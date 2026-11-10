defmodule ServiceRadar.Edge.RecoveryProjectionCost do
  @moduledoc """
  Conservative logical write accounting for a recovery control record.

  Any page or tombstone may complete receipt, so every control declares the cost
  of the WHOLE registered loss manifest, not just its own page. A registration
  covers at most 1024 selected slots and therefore at most 1024 loss spans.

  Six row writes per span cover audit insertion/update, first outcome, range or
  generation fence, retry intent and a possible quarantine transition. Sixteen
  fixed rows cover receipt, operation/generation progress, completion and ledger.

  The byte allowance is 1 MiB fixed plus 32 KiB per span. The closed mapping
  grammar bounds encoded keys below 2560 bytes, values below 1024 and attributed
  spans below 512 (including maximum scalar widths); agent IDs are <=256 bytes,
  at most1536 escaped JSON bytes. Even with repeated keys/values in audit, range
  and intent rows, this leaves room for row and identity-index payloads. The
  fixed allowance covers the <=512 KiB registration, <=256 KiB control payload
  and fixed metadata. These are logical admission units, not physical WAL bytes.
  """

  alias ServiceRadar.Edge.BoundedList
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1

  @max_spans 1024
  @max_rows 8192
  @fixed_rows 16
  @rows_per_span 6
  @fixed_bytes 1_048_576
  @bytes_per_span 32_768
  @max_bytes @fixed_bytes + @bytes_per_span * @max_spans

  def max_rows, do: @max_rows
  def max_bytes, do: @max_bytes

  @doc "Required cost from the complete validated registration's pages."
  def required(pages) do
    with true <- BoundedList.within?(pages, 1024),
         {:ok, count} <- count_spans(pages) do
      {:ok,
       %{
         rows: @fixed_rows + @rows_per_span * count,
         bytes: @fixed_bytes + @bytes_per_span * count
       }}
    else
      _ -> {:error, :recovery_projection_cost}
    end
  end

  @doc "Refuses under-declaration and declarations exceeding the catalog ceiling."
  def validate(pages, %{rows: rows, bytes: bytes} = declared)
      when map_size(declared) == 2 and is_integer(rows) and is_integer(bytes) do
    with {:ok, required} <- required(pages),
         true <- rows >= required.rows and rows <= @max_rows,
         true <- bytes >= required.bytes and bytes <= @max_bytes do
      :ok
    else
      _ -> {:error, :recovery_projection_cost}
    end
  end

  def validate(_, _), do: {:error, :recovery_projection_cost}

  defp count_spans(pages) do
    Enum.reduce_while(pages, {:ok, 0}, fn
      %EdgeLossManifestPageV1{classification_spans: spans}, {:ok, count} ->
        if BoundedList.within?(spans, 256) do
          total = count + length(spans)
          if total <= @max_spans, do: {:cont, {:ok, total}}, else: {:halt, :error}
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end
end
