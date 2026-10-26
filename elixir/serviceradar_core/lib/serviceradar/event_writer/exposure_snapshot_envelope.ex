defmodule ServiceRadar.EventWriter.ExposureSnapshotEnvelope do
  @moduledoc "Bounded immutable snapshot pages and contiguous manifest receipts."

  @max_bytes 512 * 1024
  @max_records 500
  @empty_digest String.duplicate("0", 64)
  @lanes Enum.map(0..15, &"device-#{&1}") ++ ["cve", "package"]

  def lanes, do: @lanes
  def empty_receipt, do: %{"page" => 0, "count" => 0, "digest" => @empty_digest}
  def empty_manifest, do: Map.new(@lanes, &{&1, empty_receipt()})

  def lane("device-" <> bucket), do: String.to_integer(bucket)
  def lane("cve"), do: 16
  def lane("package"), do: 17

  def subject(generation, lane, page), do: "exposure.snapshots.#{generation}.#{lane}.#{page}"

  def encode(envelope) do
    envelope =
      Map.put(
        envelope,
        "content_digest",
        digest(canonical(Map.delete(envelope, "content_digest")))
      )

    body = canonical(envelope)

    if byte_size(body) <= @max_bytes and valid?(envelope) do
      {:ok, body, digest(body)}
    else
      {:error, :invalid_exposure_snapshot_envelope}
    end
  end

  def decode(body) when is_binary(body) and byte_size(body) <= @max_bytes do
    with {:ok, envelope} <- Jason.decode(body),
         true <- valid?(envelope),
         true <-
           envelope["content_digest"] == digest(canonical(Map.delete(envelope, "content_digest"))),
         true <- canonical(envelope) == body do
      {:ok, envelope, digest(body)}
    else
      _ -> {:error, :invalid_exposure_snapshot_envelope}
    end
  end

  def decode(_), do: {:error, :invalid_exposure_snapshot_envelope}

  def page(generation, lane, receipt, phase, records) do
    %{
      "version" => 1,
      "generation" => generation["id"],
      "scope" => generation["scope"],
      "fence" => digest(generation["snapshot"]),
      "lane" => lane,
      "page" => receipt["page"] + 1,
      "previous" => receipt["digest"],
      "phase" => phase,
      "count" => length(records),
      "records" => records
    }
  end

  @doc "Admit the next page only; a duplicate cannot close a hole in a lane."
  def advance(receipt, envelope, hash) do
    cond do
      envelope["page"] == receipt["page"] and hash == receipt["digest"] ->
        {:ok, receipt}

      envelope["page"] == receipt["page"] + 1 and
          envelope["previous"] == receipt["digest"] ->
        {:ok,
         %{
           "page" => envelope["page"],
           "count" => receipt["count"] + envelope["count"],
           "digest" => hash
         }}

      true ->
        {:error, :exposure_snapshot_receipt_conflict}
    end
  end

  @doc "Split a bounded source page before publishing or reserving receiver work."
  def split(generation, lane, receipt, phase, records) when length(records) <= @max_records do
    split(generation, lane, receipt, phase, records, [])
  end

  defp split(_generation, _lane, _receipt, _phase, [], pages), do: {:ok, Enum.reverse(pages)}

  defp split(generation, lane, receipt, phase, records, pages) do
    case fit(generation, lane, receipt, phase, records) do
      {:ok, envelope, body, hash, rest} ->
        {:ok, next} = advance(receipt, envelope, hash)
        split(generation, lane, next, phase, rest, [{envelope, body, hash} | pages])

      error ->
        error
    end
  end

  defp fit(generation, lane, receipt, phase, records) do
    fit(generation, lane, receipt, phase, records, [])
  end

  defp fit(_generation, _lane, _receipt, _phase, [], _rest),
    do: {:error, :exposure_snapshot_record_too_large}

  defp fit(generation, lane, receipt, phase, records, rest) do
    envelope = page(generation, lane, receipt, phase, records)

    case encode(envelope) do
      {:ok, body, hash} ->
        {:ok, envelope, body, hash, rest}

      _ ->
        {prefix, [last]} = Enum.split(records, -1)
        fit(generation, lane, receipt, phase, prefix, [last | rest])
    end
  end

  def canonical(value), do: value |> json() |> IO.iodata_to_binary()
  def digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp json(value) when is_map(value) do
    fields =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", json(item)] end)

    ["{", Enum.intersperse(fields, ","), "}"]
  end

  defp json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &json/1), ","), "]"]

  defp json(value), do: Jason.encode!(value)

  defp valid?(
         %{"version" => 1, "generation" => id, "scope" => scope, "fence" => fence} = envelope
       )
       when is_integer(id) and id > 0 and (is_nil(scope) or is_integer(scope)) and
              is_binary(fence) do
    valid_scope?(scope) and hash?(fence) and valid_content?(envelope)
  end

  defp valid?(_), do: false
  defp valid_scope?(nil), do: true
  defp valid_scope?(scope), do: scope in 1..4_294_967_295
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_content?(%{
         "lane" => lane,
         "page" => page,
         "phase" => phase,
         "previous" => previous,
         "count" => count,
         "records" => records
       }) do
    lane in @lanes and is_integer(page) and page > 0 and
      ((phase == "dimensions" and lane in ["cve", "package"]) or
         (phase in ["lifecycle", "facts"] and lane not in ["cve", "package"])) and hash?(previous) and
      is_list(records) and length(records) in 1..@max_records and count == length(records)
  end

  defp valid_content?(%{"kind" => "start", "snapshot" => snapshot}), do: is_binary(snapshot)

  defp valid_content?(%{"kind" => "end", "manifest" => manifest}) when is_map(manifest) do
    Enum.sort(Map.keys(manifest)) == Enum.sort(@lanes) and
      Enum.all?(manifest, fn {_lane, receipt} -> valid_receipt?(receipt) end)
  end

  defp valid_content?(_), do: false

  defp valid_receipt?(%{"page" => page, "count" => count, "digest" => hash}),
    do: is_integer(page) and page >= 0 and is_integer(count) and count >= 0 and hash?(hash)

  defp valid_receipt?(_), do: false
end
