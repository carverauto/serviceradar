defmodule ServiceRadar.EventWriter.ExposureRecovery do
  @moduledoc """
  Immutable, bounded JetStream inputs for unfinished exposure deliveries.
  CNPG holds only their identity, hash and position. Completed inputs are deleted
  explicitly; neither age nor a full stream can evict an unfinished operation.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetstreamConsumer

  @stream "EXPOSURE_RECOVERY"
  @max_records 500
  @max_bytes 512 * 1024
  @config %{
    "name" => @stream,
    "subjects" => ["exposure.delivery.recovery.>", "exposure.snapshots.>"],
    "retention" => "limits",
    "storage" => "file",
    "num_replicas" => 1,
    "max_age" => 0,
    "max_bytes" => 64 * 1024 * 1024,
    "max_msg_size" => @max_bytes,
    "max_msgs_per_subject" => 1,
    "discard" => "new",
    "discard_new_per_subject" => true,
    "deny_purge" => true,
    "deny_delete" => false,
    "allow_rollup_hdrs" => false
  }

  @doc "Split before journal admission, reserving space for the envelope header."
  def split(entries) do
    entries
    |> Enum.reduce_while({:ok, [], [], 0, 0}, fn entry, {:ok, pages, page, count, bytes} ->
      size = byte_size(Jason.encode!(wire_entry(entry))) + 1

      cond do
        size + 128 > @max_bytes ->
          {:halt, {:error, :exposure_recovery_record_too_large}}

        count == @max_records or bytes + size + 128 > @max_bytes ->
          {:cont, {:ok, [Enum.reverse(page) | pages], [entry], 1, size}}

        true ->
          {:cont, {:ok, pages, [entry | page], count + 1, bytes + size}}
      end
    end)
    |> case do
      {:ok, pages, [], _, _} -> {:ok, Enum.reverse(pages)}
      {:ok, pages, page, _, _} -> {:ok, Enum.reverse([Enum.reverse(page) | pages])}
      error -> error
    end
  end

  def encode(bucket, id, entries) do
    body = Jason.encode!([1, id, bucket, Enum.map(entries, &wire_entry/1)])

    if entries != [] and length(entries) <= @max_records and byte_size(body) <= @max_bytes do
      {:ok, body, digest(body)}
    else
      {:error, :exposure_recovery_envelope_too_large}
    end
  end

  def retain(bucket, id, body, hash) do
    retain_envelope(subject(bucket, id), body, hash)
  end

  @doc "Retain a bounded immutable envelope on an owned recovery subject."
  def retain_envelope(subject, body, hash) when byte_size(body) <= @max_bytes do
    with true <- digest(body) == hash,
         :ok <- ensure_stream() do
      case request(subject, body) do
        {:ok, %{"stream" => @stream, "seq" => seq}} when is_integer(seq) and seq > 0 ->
          {:ok, seq}

        result ->
          # Covers lost PubAck and insert-only subject conflicts, without relying
          # on JetStream's time-limited duplicate window.
          case fetch_envelope(subject, hash) do
            {:ok, seq, _body} -> {:ok, seq}
            :missing -> {:error, {:exposure_recovery_publish, result}}
            error -> error
          end
      end
    else
      false -> {:error, :exposure_recovery_content_conflict}
      error -> error
    end
  end

  def retain_envelope(_subject, _body, _hash), do: {:error, :exposure_recovery_envelope_too_large}

  def fetch(bucket, id, hash, position \\ nil) do
    with {:ok, seq, body} <- fetch_envelope(subject(bucket, id), hash, position),
         {:ok, [1, ^id, ^bucket, rows]} when is_list(rows) <- Jason.decode(body),
         {:ok, entries} <- decode_rows(rows, bucket) do
      {:ok, seq, entries}
    else
      :missing -> :missing
      {:error, _} = error -> error
      _ -> {:error, :exposure_recovery_content_conflict}
    end
  end

  @doc "Read an exact retained position (or uncertain publication) and verify its bytes."
  def fetch_envelope(expected_subject, hash, position \\ nil) do
    selector = if position, do: %{seq: position}, else: %{last_by_subj: expected_subject}

    case request("$JS.API.STREAM.MSG.GET.#{@stream}", Jason.encode!(selector)) do
      {:ok, %{"message" => %{"subject" => ^expected_subject, "seq" => seq, "data" => data}}}
      when is_integer(seq) and seq > 0 ->
        with {:ok, body} <- Base.decode64(data),
             true <- byte_size(body) <= @max_bytes and digest(body) == hash do
          {:ok, seq, body}
        else
          _ -> {:error, :exposure_recovery_content_conflict}
        end

      {:ok, %{"error" => %{"code" => 404}}} ->
        :missing

      other ->
        {:error, {:exposure_recovery_read, other}}
    end
  end

  def delete(position) when is_integer(position) and position > 0 do
    outcome = request("$JS.API.STREAM.MSG.DELETE.#{@stream}", Jason.encode!(%{seq: position}))

    case outcome do
      {:ok, %{"success" => true}} -> :ok
      _ -> confirm_absent(position, outcome)
    end
  end

  defp confirm_absent(position, delete_result) do
    case request("$JS.API.STREAM.MSG.GET.#{@stream}", Jason.encode!(%{seq: position})) do
      {:ok, %{"error" => %{"err_code" => 10_037}}} ->
        :ok

      {:ok, %{"message" => %{"seq" => ^position}}} ->
        {:error, {:exposure_recovery_cleanup, delete_result}}

      other ->
        {:error, {:exposure_recovery_cleanup, other}}
    end
  end

  def ensure_stream do
    case JetstreamConsumer.stream_info(&request/2, @stream) do
      {:ok, config, _bytes} ->
        validate_config(config)

      :absent ->
        # A concurrent creator is harmless only if its effective configuration
        # satisfies the same retention contract; never rewrite a conflicting one.
        request("$JS.API.STREAM.CREATE.#{@stream}", Jason.encode!(@config))

        case JetstreamConsumer.stream_info(&request/2, @stream) do
          {:ok, config, _bytes} -> validate_config(config)
          other -> {:error, {:exposure_recovery_stream, other}}
        end

      error ->
        error
    end
  end

  defp validate_config(config) do
    mismatches =
      Enum.flat_map(@config, fn {key, value} ->
        actual = Map.get(config, key, if(is_boolean(value), do: false))
        if actual == value, do: [], else: [key]
      end)

    if mismatches == [], do: :ok, else: {:error, {:exposure_recovery_stream_config, mismatches}}
  end

  defp decode_rows(rows, bucket) when length(rows) in 1..@max_records do
    expected_subject = "vulnerability.assessment.transitions.#{bucket}"

    rows
    |> Enum.reduce_while({:ok, []}, fn
      [seq, ^expected_subject, data], {:ok, entries}
      when is_integer(seq) and seq > 0 and is_binary(data) ->
        message = %{data: data, metadata: %{subject: expected_subject}}
        {:cont, {:ok, [{seq, message} | entries]}}

      _, _ ->
        {:halt, {:error, :invalid_recovery_envelope}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp decode_rows(_, _), do: {:error, :invalid_recovery_envelope}
  defp wire_entry({seq, message}), do: [seq, message.metadata.subject, message.data]
  defp subject(bucket, id), do: "exposure.delivery.recovery.#{bucket}.#{id}"
  defp digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp request(subject, body) do
    with {:ok, conn} <- Connection.get(),
         {:ok, %{body: response}} <- Gnat.request(conn, subject, body, receive_timeout: 5_000) do
      Jason.decode(response)
    end
  end
end
