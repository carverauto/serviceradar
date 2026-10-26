defmodule ServiceRadar.EventWriter.ExposureDelivery do
  @moduledoc """
  Serializes exposure deliveries across replicas, using sixteen CNPG session
  locks and a durable journal of JetStream positions, never telemetry payloads.

  A replacement owner replays an unfinished batch before admitting another one.
  This matters when its predecessor died with a Stream Load still in flight:
  replay reconciles the same immutable load labels before retirement can pass.
  New deliveries retain an immutable JetStream copy until completion. Legacy
  journals without recoverable inputs remain blocked rather than forgetting an
  uncertain warehouse load.

  The bucket locks are held on a `ServiceRadar.Repo.DirectSession`, never on the
  pooled Repo: a transaction-mode pooler can run the lock and the unlock on
  different server backends and strand the lock on a shared one. Each run opens
  its own session, so a dead owner's locks end with its connection. Every
  ownership check asks whether that session still holds the bucket lock; when
  it does not, the batch fails with `:exposure_delivery_ownership_lost` and its
  journal entry stays for the next owner to replay. The journal is written
  through the Repo, one autocommitted statement at a time, so a batch is
  journaled durably before its load starts. An insert that finds the bucket row
  already there does nothing and the batch is busy, without a load. Finishing
  marks complete, deletes the envelope, and removes the journal only while that
  row is still the operation this run created or adopted. The same source
  positions under another operation stay in place, including its phase and
  recovery position. Legacy adoption is the only update that claims a journal
  with no operation id, and only while that id is still null.

  Namespace 74523 was never in a tagged release (it landed after v1.4.97), so a
  mixed-version overlap only affects an installation running an untagged
  staging build during this upgrade. Draining to one EventWriter for that
  upgrade is optional.
  """
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope
  alias ServiceRadar.EventWriter.ExposureSnapshotIngestion
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  # 74_523 was taken through the pooled Repo, where unlocks could miss and
  # leave it stranded on a server connection. 74_524 is the exposure sequence
  # lock, so delivery uses its own class. Objid stays the bucket, 0..15.
  @lock_namespace 74_525
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
      case DirectSession.run(fn session ->
             {loaded, failure} =
               Enum.reduce(buckets, {0, nil}, fn {bucket, entries}, {count, failure} ->
                 case deliver(session, bucket, entries, ingest) do
                   {:ok, loaded} -> {count + loaded, failure}
                   error -> {count, failure || error}
                 end
               end)

             failure || {:ok, loaded}
           end) do
        {:error, {:direct_session_unavailable, reason}} ->
          {:error, {:exposure_delivery_session_unavailable, reason}}

        result ->
          result
      end
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

  @doc "Delete delayed recovery publications only after their journal ownership has ended."
  def cleanup_unowned_copy(subject, body, position) do
    with {:ok, [1, id, bucket, _entries]} <- Jason.decode(body),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- bucket in 0..15 and subject == "exposure.delivery.recovery.#{bucket}.#{id}" do
      DirectSession.run(fn session ->
        lock(session, bucket, fn _owned ->
          case Repo.query!(
                 """
                 SELECT payload_hash FROM platform.exposure_delivery_batches
                 WHERE bucket = $1 AND operation_id = $2::text::uuid
                 """,
                 [bucket, id]
               ).rows do
            [[hash]] ->
              if ExposureSnapshotEnvelope.digest(body) == hash,
                do: :ok,
                else: {:error, :exposure_recovery_content_conflict}

            [] ->
              ExposureRecovery.delete(position)
          end
        end)
      end)
    else
      _ -> {:error, :invalid_exposure_recovery_message}
    end
  end

  @doc "Snapshot labels name both the generation and the actual physical chunk bytes."
  def persist_snapshot(dataset, rows, locked, identity, limits) do
    Destination.persist_warehouse(dataset, rows,
      stream_load: limits,
      persist: fn table, chunk, opts ->
        digest =
          ExposureSnapshotEnvelope.digest(
            ExposureSnapshotEnvelope.canonical([table, identity, chunk])
          )

        with :ok <- locked.(),
             result =
               StreamLoad.persist(
                 table,
                 chunk,
                 Keyword.put(opts, :label, "exposure-snapshot-" <> digest)
               ),
             :ok <- locked.() do
          result
        end
      end
    )
  end

  @doc "Shared live/snapshot ownership, including the two dictionary lanes."
  def with_lane(lane, fun, opts \\ []) when lane in 0..17 do
    DirectSession.run(fn session ->
      lock(session, lane, fn locked ->
        with :ok <-
               ExposureSnapshotIngestion.release_unstarted(
                 Keyword.get(opts, :snapshot),
                 lane,
                 locked
               ),
             :ok <- settle_retained(lane, locked, fn -> recover_live(lane, locked) end) do
          fun.(locked)
        end
      end)
    end)
  end

  defp recover_live(lane, locked) when lane in 0..15,
    do: recover(lane, &ExposureTransitions.ingest_batch/2, locked)

  defp recover_live(_lane, _locked), do: :ok

  defp settle_retained(lane, locked, recover) do
    with :ok <- ExposureSnapshotIngestion.settle(lane, locked), do: recover.()
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
    lock(session, bucket, fn locked -> deliver_owned(bucket, entries, ingest, locked) end)
  end

  defp lock(session, bucket, fun) do
    case Postgrex.query(session, "SELECT pg_try_advisory_lock($1, $2)", [
           @lock_namespace,
           bucket
         ]) do
      {:ok, %Postgrex.Result{rows: [[true]]}} ->
        try do
          fun.(fn -> owned(session, bucket) end)
        after
          # Frees the bucket while later buckets of this run deliver. If the
          # session was lost, it holds nothing and closing it is enough.
          _ =
            Postgrex.query(session, "SELECT pg_advisory_unlock($1, $2)", [
              @lock_namespace,
              bucket
            ])
        end

      {:ok, %Postgrex.Result{rows: [[false]]}} ->
        {:error, :exposure_delivery_busy}

      {:error, reason} ->
        {:error, {:exposure_delivery_session_unavailable, reason}}
    end
  end

  defp deliver_owned(bucket, entries, ingest, locked) do
    with :ok <- settle_retained(bucket, locked, fn -> recover(bucket, ingest, locked) end) do
      entries = entries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))
      deliver_pages(bucket, entries, ingest, locked)
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
           """
           SELECT stream_sequences, phase, operation_id::text, payload_hash, recovery_position
           FROM platform.exposure_delivery_batches WHERE bucket = $1
           """,
           [bucket]
         ).rows do
      [] ->
        :ok

      [journal] ->
        recover_journal(bucket, journal, ingest, locked)
    end
  end

  defp deliver_pages(bucket, entries, ingest, locked) do
    with {:ok, pages} <- ExposureRecovery.split(entries) do
      Enum.reduce_while(pages, {:ok, 0}, fn page, {:ok, loaded} ->
        case capture(bucket, page, ingest, locked) do
          {:ok, count} -> {:cont, {:ok, loaded + count}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp capture(bucket, entries, ingest, locked) do
    id = Ecto.UUID.generate()
    sequences = sequences(entries)

    with {:ok, body, hash} <- ExposureRecovery.encode(bucket, id, entries),
         :ok <- locked.() do
      case Repo.query!(
             """
             INSERT INTO platform.exposure_delivery_batches
               (bucket, stream_sequences, phase, operation_id, payload_hash)
             VALUES ($1, $2::bigint[], 'capturing', $3::text::uuid, $4)
             ON CONFLICT DO NOTHING
             RETURNING bucket
             """,
             [bucket, sequences, id, hash]
           ) do
        %{num_rows: 1} ->
          retain_and_apply(bucket, id, hash, body, entries, ingest, locked)

        %{num_rows: 0} ->
          {:error, :exposure_delivery_busy}
      end
    end
  end

  defp recover_journal(bucket, [sequences, "complete", id, _hash, position], _ingest, locked),
    do: cleanup(bucket, id, sequences, position, locked)

  defp recover_journal(bucket, [_sequences, "snapshot_required", _, _, _], _ingest, _locked),
    do: {:error, {:exposure_snapshot_required, bucket}}

  defp recover_journal(bucket, [sequences, "legacy", nil, nil, nil], ingest, locked) do
    # A legacy batch may already have issued a load. Preserve its exact grouping
    # (and therefore labels), and never treat failed capture as unstarted work.
    with {:ok, entries} <- fetch_messages(sequences, bucket),
         id = Ecto.UUID.generate(),
         {:ok, body, hash} <- ExposureRecovery.encode(bucket, id, entries),
         :ok <- locked.() do
      case Repo.query!(
             """
             UPDATE platform.exposure_delivery_batches
             SET operation_id = $2::text::uuid, payload_hash = $3
             WHERE bucket = $1 AND stream_sequences = $4::bigint[]
               AND phase = 'legacy' AND operation_id IS NULL
             """,
             [bucket, id, hash, sequences]
           ) do
        %{num_rows: 1} ->
          recovered(retain_and_apply(bucket, id, hash, body, entries, ingest, locked))

        %{num_rows: 0} ->
          {:error, :exposure_delivery_busy}
      end
    end
  end

  defp recover_journal(bucket, [sequences, phase, id, hash, position], ingest, locked) do
    case ExposureRecovery.fetch(bucket, id, hash, position) do
      {:ok, retained_position, entries} ->
        if sequences(entries) == sequences do
          recovered(
            apply_retained(bucket, id, sequences, retained_position, entries, ingest, locked)
          )
        else
          {:error, :exposure_recovery_content_conflict}
        end

      :missing when phase in ["capturing", "legacy"] ->
        recover_capture(bucket, sequences, phase, id, hash, ingest, locked)

      :missing ->
        {:error, {:exposure_recovery_input_lost, bucket}}

      error ->
        error
    end
  end

  defp recover_capture(bucket, sequences, phase, id, hash, ingest, locked) do
    with {:ok, entries} <- fetch_messages(sequences, bucket),
         {:ok, body, ^hash} <- ExposureRecovery.encode(bucket, id, entries) do
      recovered(retain_and_apply(bucket, id, hash, body, entries, ingest, locked))
    else
      {:error, {:exposure_recovery_message_unavailable, _}} = error ->
        if phase == "capturing" do
          with :ok <- locked.() do
            case Repo.query!(
                   """
                   UPDATE platform.exposure_delivery_batches
                   SET phase = 'snapshot_required'
                   WHERE bucket = $1 AND stream_sequences = $2::bigint[]
                     AND operation_id = $3::text::uuid AND phase = 'capturing'
                   """,
                   [bucket, sequences, id]
                 ) do
              %{num_rows: 1} -> {:error, {:exposure_snapshot_required, bucket}}
              %{num_rows: 0} -> {:error, :exposure_delivery_busy}
            end
          end
        else
          error
        end

      {:ok, _, _} ->
        {:error, :exposure_recovery_content_conflict}

      error ->
        error
    end
  end

  defp retain_and_apply(bucket, id, hash, body, entries, ingest, locked) do
    with :ok <- locked.(),
         {:ok, position} <- ExposureRecovery.retain(bucket, id, body, hash) do
      apply_retained(bucket, id, sequences(entries), position, entries, ingest, locked)
    end
  end

  defp apply_retained(bucket, id, sequences, position, entries, ingest, locked) do
    with :ok <- locked.() do
      case Repo.query!(
             """
             UPDATE platform.exposure_delivery_batches
             SET phase = 'applying', recovery_position = $2
             WHERE bucket = $1 AND stream_sequences = $3::bigint[]
               AND operation_id = $4::text::uuid
             """,
             [bucket, position, sequences, id]
           ) do
        %{num_rows: 1} ->
          finish(
            bucket,
            id,
            sequences,
            position,
            ingest.(Enum.map(entries, &elem(&1, 1)), locked),
            locked
          )

        %{num_rows: 0} ->
          {:error, :exposure_delivery_busy}
      end
    end
  end

  defp finish(bucket, id, sequences, position, result, locked)
       when elem(result, 0) in [:ok, :retry] do
    with :ok <- locked.() do
      case Repo.query!(
             """
             UPDATE platform.exposure_delivery_batches
             SET phase = 'complete'
             WHERE bucket = $1 AND stream_sequences = $2::bigint[]
               AND operation_id = $3::text::uuid
             """,
             [bucket, sequences, id]
           ) do
        %{num_rows: 1} ->
          with :ok <- cleanup(bucket, id, sequences, position, locked) do
            accepted(result)
          end

        %{num_rows: 0} ->
          accepted(result)
      end
    end
  end

  defp finish(_bucket, _id, _sequences, _position, error, _locked), do: error

  defp cleanup(bucket, id, sequences, position, locked) do
    with :ok <- locked.(),
         :ok <- ExposureRecovery.delete(position),
         :ok <- locked.() do
      Repo.query!(
        """
        DELETE FROM platform.exposure_delivery_batches
        WHERE bucket = $1 AND stream_sequences = $2::bigint[]
          AND operation_id = $3::text::uuid
        """,
        [bucket, sequences, id]
      )

      :ok
    end
  end

  defp accepted({:retry, reason}), do: {:error, reason}
  defp accepted(success), do: success

  defp recovered(result) do
    case result do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp sequences(entries), do: Enum.map(entries, &elem(&1, 0))

  defp fetch_messages(sequences, bucket) do
    sequences
    |> Enum.reduce_while({:ok, []}, fn seq, {:ok, acc} ->
      case fetch_message(seq, bucket) do
        {:ok, message} -> {:cont, {:ok, [{seq, message} | acc]}}
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

    with {:ok, %{body: body}} <- request(seq),
         {:ok, response} <- Jason.decode(body) do
      case response do
        %{"message" => %{"seq" => ^seq, "subject" => ^subject, "data" => data}} ->
          case Base.decode64(data) do
            {:ok, payload} -> {:ok, %{data: payload, metadata: %{subject: subject}}}
            :error -> {:error, {:exposure_recovery_source_encoding, seq}}
          end

        %{"error" => %{"code" => 404}} ->
          {:error, {:exposure_recovery_message_unavailable, seq}}

        other ->
          {:error, {:exposure_recovery_source_read, other}}
      end
    end
  end
end
