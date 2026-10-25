defmodule ServiceRadar.EventWriter.ExposureDelivery do
  @moduledoc """
  Serializes exposure deliveries across replicas, using sixteen CNPG session
  locks and a durable journal of JetStream positions, never telemetry payloads.

  A replacement owner replays an unfinished batch before admitting another one.
  This matters when its predecessor died with a Stream Load still in flight:
  replay reconciles the same immutable load labels before retirement can pass.
  An expired stream position fails closed and requires snapshot recovery.

  The bucket locks are held on a `ServiceRadar.Repo.DirectSession`, never on the
  pooled Repo: a transaction-mode pooler can run the lock and the unlock on
  different server backends and strand the lock on a shared one. Each run opens
  its own session, so a dead owner's locks end with its connection. Every
  ownership check asks whether that session still holds the bucket lock; when
  it does not, the batch fails with `:exposure_delivery_ownership_lost` and its
  journal entry stays for the next owner to replay. The journal is written
  through the Repo, one autocommitted statement at a time, so a batch is
  journaled durably before its load starts.
  """
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  # 74_523 was taken through the pooled Repo, where unlocks could miss and leave
  # it held by pooled server connections, so ownership moved to a fresh namespace.
  @lock_namespace 74_524
  # pg_try_advisory_lock(int4, int4) is recorded as classid, objid, objsubid 2.
  @lock_held_sql """
  SELECT EXISTS (
    SELECT 1 FROM pg_locks
    WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()
      AND classid::bigint = $1 AND objid::bigint = $2 AND objsubid = 2
  )
  """
  @stream "EXPOSURE_TRANSITIONS"

  def run(messages, ingest) do
    with {:ok, buckets} <- positions(messages) do
      DirectSession.run(fn session ->
        {loaded, failure} =
          Enum.reduce(buckets, {0, nil}, fn {bucket, entries}, {count, failure} ->
            case deliver(session, bucket, entries, ingest) do
              {:ok, loaded} -> {count + loaded, failure}
              error -> {count, failure || error}
            end
          end)

        failure || {:ok, loaded}
      end)
    end
  end

  @doc """
  Checks ownership before and after every physical load, including size-split
  batches. A lost bucket lock is returned as an error, never raised, so the
  batch fails and is redelivered while its journal stays for the next owner.
  """
  def persist(dataset, rows, locked) do
    limits = Keyword.put(Destination.stream_load_limits(), :max_in_flight, 1)

    Destination.persist_warehouse(dataset, rows,
      stream_load: limits,
      persist: fn table, chunk, opts ->
        with :ok <- locked.(),
             result = StreamLoad.persist(table, chunk, opts),
             :ok <- locked.() do
          result
        end
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

  defp deliver(session, bucket, entries, ingest) do
    case Postgrex.query(session, "SELECT pg_try_advisory_lock($1, $2)", [@lock_namespace, bucket]) do
      {:ok, %Postgrex.Result{rows: [[true]]}} ->
        try do
          deliver_owned(bucket, entries, ingest, fn -> owned(session, bucket) end)
        after
          # Frees the bucket while later buckets of this run deliver. If the
          # session was lost, it holds nothing and closing it is enough.
          _ =
            Postgrex.query(session, "SELECT pg_advisory_unlock($1, $2)", [@lock_namespace, bucket])
        end

      {:ok, %Postgrex.Result{rows: [[false]]}} ->
        {:error, :exposure_delivery_busy}

      {:error, reason} ->
        {:error, {:exposure_delivery_session_unavailable, reason}}
    end
  end

  defp deliver_owned(bucket, entries, ingest, locked) do
    with :ok <- recover(bucket, ingest, locked) do
      entries = entries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))

      Repo.query!(
        "INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences) VALUES ($1, $2)",
        [bucket, Enum.map(entries, &elem(&1, 0))]
      )

      finish(bucket, ingest.(Enum.map(entries, &elem(&1, 1)), locked), locked)
    end
  end

  # Whether this run's session still holds the bucket lock. A dropped session
  # reconnects holding nothing, and a failed query proves nothing, so both fail
  # closed.
  defp owned(session, bucket) do
    case Postgrex.query(session, @lock_held_sql, [@lock_namespace, bucket]) do
      {:ok, %Postgrex.Result{rows: [[true]]}} -> :ok
      _ -> {:error, :exposure_delivery_ownership_lost}
    end
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
    with :ok <- locked.() do
      Repo.query!("DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1", [bucket])

      case result do
        {:retry, reason} -> {:error, reason}
        success -> success
      end
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
