defmodule ServiceRadar.EventWriter.ExposureDelivery do
  @moduledoc """
  Serializes exposure deliveries across replicas, using sixteen CNPG session
  locks and a durable journal of JetStream positions, never telemetry payloads.

  A replacement owner replays an unfinished batch before admitting another one.
  This matters when its predecessor died with a Stream Load still in flight:
  replay reconciles the same immutable load labels before retirement can pass.
  An expired stream position fails closed and requires snapshot recovery.
  """
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Repo

  @lock_namespace 74_523
  @stream "EXPOSURE_TRANSITIONS"

  def run(messages, ingest) do
    with {:ok, buckets} <- positions(messages) do
      {loaded, failure} =
        Enum.reduce(buckets, {0, nil}, fn {bucket, entries}, {count, failure} ->
          case deliver(bucket, entries, ingest) do
            {:ok, loaded} -> {count + loaded, failure}
            error -> {count, failure || error}
          end
        end)

      failure || {:ok, loaded}
    end
  end

  @doc "Checks ownership before every physical load, including size-split batches."
  def persist(dataset, rows, locked) do
    limits = Keyword.put(Destination.stream_load_limits(), :max_in_flight, 1)

    Destination.persist_warehouse(dataset, rows,
      stream_load: limits,
      persist: fn table, chunk, opts ->
        :ok = locked.()
        result = StreamLoad.persist(table, chunk, opts)
        :ok = locked.()
        result
      end
    )
  end

  defp positions(messages) do
    Enum.reduce_while(messages, {:ok, %{}}, fn message, {:ok, buckets} ->
      ack = Map.get(message.metadata, :jetstream_ack)
      subject = Map.get(message.metadata, :subject, "")

      case {ack, String.split(subject, "."), Jason.decode(message.data)} do
        {%{stream: @stream, stream_sequence: seq},
         ["vulnerability", "assessment", "transitions", bucket], {:ok, %{"device_uid" => uid}}}
        when is_integer(seq) and seq > 0 and is_binary(uid) ->
          case Integer.parse(bucket) do
            {bucket, ""} when bucket in 0..15 ->
              if ExposureTransitionRelay.subject(uid) == subject do
                {:cont,
                 {:ok, Map.update(buckets, bucket, [{seq, message}], &[{seq, message} | &1])}}
              else
                {:halt, {:error, :invalid_exposure_stream_position}}
              end

            _ ->
              {:halt, {:error, :invalid_exposure_stream_position}}
          end

        _ ->
          {:halt, {:error, :invalid_exposure_stream_position}}
      end
    end)
  end

  defp deliver(bucket, entries, ingest) do
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock($1, $2), pg_backend_pid()", [
               @lock_namespace,
               bucket
             ]).rows do
          [[true, backend]] ->
            try do
              locked = fn ->
                [[^backend]] = Repo.query!("SELECT pg_backend_pid()").rows
                :ok
              end

              with :ok <- recover(bucket, ingest, locked) do
                entries = entries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))

                Repo.query!(
                  "INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences) VALUES ($1, $2)",
                  [bucket, Enum.map(entries, &elem(&1, 0))]
                )

                finish(bucket, ingest.(Enum.map(entries, &elem(&1, 1)), locked), locked)
              end
            after
              Repo.query!("SELECT pg_advisory_unlock($1, $2)", [@lock_namespace, bucket])
            end

          [[false, _]] ->
            {:error, :exposure_delivery_busy}
        end
      end,
      timeout: 120_000
    )
  end

  defp recover(bucket, ingest, locked) do
    case Repo.query!(
           "SELECT stream_sequences FROM platform.exposure_delivery_batches WHERE bucket = $1",
           [bucket]
         ).rows do
      [] ->
        :ok

      [[sequences]] ->
        with {:ok, messages} <- fetch_messages(sequences, bucket),
             {:ok, _} <- finish(bucket, ingest.(messages, locked), locked) do
          :ok
        end
    end
  end

  defp finish(bucket, result, locked) when elem(result, 0) in [:ok, :retry] do
    :ok = locked.()
    Repo.query!("DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1", [bucket])

    case result do
      {:retry, reason} -> {:error, reason}
      success -> success
    end
  end

  defp finish(_bucket, error, _locked), do: error

  defp fetch_messages(sequences, bucket) do
    sequences
    |> Enum.reduce_while({:ok, []}, fn seq, {:ok, acc} ->
      case fetch_message(seq, bucket) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp request(seq) do
    Gnat.request(
      Connection.connection_name(),
      "$JS.API.STREAM.MSG.GET.#{@stream}",
      Jason.encode!(%{seq: seq}),
      receive_timeout: 5_000
    )
  end

  defp fetch_message(seq, bucket) do
    subject = "vulnerability.assessment.transitions.#{bucket}"

    with {:ok, %{body: body}} <-
           request(seq),
         {:ok, %{"message" => %{"seq" => ^seq, "subject" => ^subject, "data" => data}}} <-
           Jason.decode(body),
         {:ok, payload} <- Base.decode64(data) do
      {:ok, %{data: payload, metadata: %{subject: subject}}}
    else
      _ -> {:error, {:exposure_recovery_message_unavailable, seq}}
    end
  end
end
