defmodule ServiceRadar.Camera.RecorderOwnership do
  @moduledoc """
  Durable recorder exclusion, generation and block allocation on shared ingest.

  Every operation locks ingest owner then recorder claim. The caller retains a
  fresh per-start token; it must never read a token back to impersonate a previous
  worker. A consumer retains ingest, but only this claim grants recording rights.
  Lease receipts use database time and are capped by both ingest and relay leases.
  Short CNPG publication callbacks recheck both fences and the persisted relay
  before commit; external I/O belongs outside the transaction and must return
  through this fence to publish.

  Reserve a block before touching disk. Allocations are never rolled back merely
  because a subsequent filesystem operation failed. Takeover increments recorder
  epoch and starts a fresh sequence, leaving old bytes for separately authorized
  recovery. Storage UUIDs identify provisioned storage, never Erlang nodes or PIDs.
  """
  import Ash.Expr

  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RelaySession

  require Ash.Query

  @max_counter 9_223_372_036_854_775_807

  def acquire(ingest, token, media_ingest_id, storage_id, ttl_ms, opts \\ []) do
    with :ok <- ttl(ttl_ms),
         {:ok, token} <- uuid(token),
         {:ok, storage_id} <- uuid(storage_id),
         true <- valid_ingest_id?(media_ingest_id) || {:error, :invalid_media_ingest_id} do
      IngestOwnership.with_current_owner(
        ingest,
        fn owner ->
          with {:ok, relay} <- active_relay(owner, media_ingest_id, owner.database_now, opts),
               {:ok, initial} <- initialize(owner.id, opts),
               {:ok, previous} <- lock(initial.id, opts),
               :ok <- available(previous, owner, token),
               {:ok, consumer} <-
                 IngestOwnership.acquire_consumer(owner, :recorder, token, ttl_ms, opts),
               {:ok, consumer} <- cap_consumer(consumer, relay.lease_expires_at, opts),
               {:ok, claim} <-
                 transition(
                   previous,
                   %{
                     claim_token: token,
                     ingest_epoch: owner.epoch,
                     recorder_epoch: previous.recorder_epoch + 1,
                     next_block_sequence: 0,
                     relay_session_id: owner.relay_session_id,
                     media_ingest_id: media_ingest_id,
                     storage_id: storage_id,
                     consumer_id: consumer.id,
                     lease_expires_at: consumer.expires_at,
                     state: :active
                   },
                   opts
                 ) do
            current(claim, owner, opts)
          end
        end,
        opts
      )
    end
  end

  def renew(ingest, claim, ttl_ms, opts \\ []) do
    with :ok <- ttl(ttl_ms) do
      with_current(
        ingest,
        claim,
        fn owner, current ->
          with {:ok, relay} <-
                 active_relay(owner, current.media_ingest_id, current.database_now, opts),
               {:ok, consumer} <-
                 IngestOwnership.renew_consumer(owner, current.consumer_id, ttl_ms, opts),
               {:ok, consumer} <- cap_consumer(consumer, relay.lease_expires_at, opts),
               do: transition(current, %{lease_expires_at: consumer.expires_at}, opts)
        end,
        opts
      )
    end
  end

  def reserve_block(ingest, claim, opts \\ []) do
    with_current(
      ingest,
      claim,
      fn _owner, current ->
        if current.next_block_sequence < @max_counter do
          sequence = current.next_block_sequence

          with {:ok, _updated} <- transition(current, %{next_block_sequence: sequence + 1}, opts),
               do: {:ok, sequence}
        else
          {:error, :block_sequence_exhausted}
        end
      end,
      opts
    )
  end

  @doc "Fences short CNPG publication using the caller's original recorder handle."
  def with_current(ingest, claim, fun, opts \\ []) when is_function(fun, 2) do
    IngestOwnership.with_current_owner(
      ingest,
      fn owner ->
        with {:ok, locked} <- lock_handle(claim, owner, opts),
             {:ok, _relay} <-
               active_relay(owner, locked.media_ingest_id, locked.database_now, opts),
             {:ok, result} <- publication_result(fun.(owner, locked)),
             {:ok, _current} <- current(claim, owner, opts) do
          {:ok, result}
        end
      end,
      opts
    )
  end

  def release(ingest, claim, opts \\ []) do
    IngestOwnership.with_current_owner(
      ingest,
      fn owner ->
        with {:ok, locked} <- lock_handle(claim, owner, opts),
             :ok <- IngestOwnership.release_consumer(owner, locked.consumer_id, opts),
             {:ok, _released} <- transition(locked, %{state: :released, consumer_id: nil}, opts),
             {:ok, now} <- Ash.load(locked, :database_now, opts),
             true <- live?(locked, now.database_now) || {:error, :recorder_claim_lost} do
          {:ok, :released}
        end
      end,
      opts
    )
  end

  defp initialize(owner_id, opts) do
    RecorderClaim
    |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner_id})
    |> Ash.create(opts)
  end

  defp lock(id, opts) do
    RecorderClaim
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> {:error, :recorder_claim_lost}
      {:ok, claim} -> Ash.load(claim, :database_now, opts)
      error -> error
    end
  end

  defp lock_handle(%{id: id} = claim, owner, opts) do
    with {:ok, locked} <- lock(id, opts), :ok <- matches(claim, locked, owner), do: {:ok, locked}
  end

  defp current(claim, owner, opts) do
    with {:ok, current} <-
           RecorderClaim
           |> Ash.Query.filter(id == ^claim.id)
           |> Ash.Query.load(:database_now)
           |> Ash.read_one(opts),
         :ok <- matches(claim, current, owner),
         {:ok, _relay} <- active_relay(owner, current.media_ingest_id, current.database_now, opts),
         do: {:ok, current}
  end

  defp matches(claim, %RecorderClaim{} = current, owner) do
    if claim.claim_token == current.claim_token and claim.recorder_epoch == current.recorder_epoch and
         current.ingest_owner_id == owner.id and current.ingest_epoch == owner.epoch and
         current.relay_session_id == owner.relay_session_id and current.consumer_id != nil and
         live?(current, current.database_now), do: :ok, else: {:error, :recorder_claim_lost}
  end

  defp matches(_claim, _current, _owner), do: {:error, :recorder_claim_lost}

  defp available(claim, owner, token) do
    cond do
      claim.ingest_epoch == owner.epoch and live?(claim, claim.database_now) ->
        {:error, :recorder_already_owned}

      claim.claim_token == token ->
        {:error, :recorder_token_reused}

      claim.recorder_epoch == @max_counter ->
        {:error, :recorder_epoch_exhausted}

      true ->
        :ok
    end
  end

  defp transition(claim, attrs, opts) do
    epoch = claim.recorder_epoch

    claim
    |> Ash.Changeset.for_update(:transition, attrs)
    |> Ash.Changeset.filter(expr(recorder_epoch == ^epoch))
    |> Ash.update(Keyword.put(opts, :load, [:database_now]))
  end

  # Legacy relay adoption can give the owner a later expiry than the relay.
  # Both writes remain inside the owner -> claim transaction; no receipt may
  # promise recording or retention past the persisted media lease.
  defp cap_consumer(consumer, expiry, opts) do
    if DateTime.after?(consumer.expires_at, expiry) do
      consumer
      |> Ash.Changeset.for_update(:renew, %{expires_at: expiry})
      |> Ash.update(Keyword.put(opts, :load, [:database_now]))
    else
      {:ok, consumer}
    end
  end

  defp active_relay(owner, ingest_id, now, opts) do
    with {:ok, %RelaySession{} = relay} <-
           RelaySession.get_by_id(
             owner.relay_session_id,
             Keyword.put(opts, :not_found_error?, false)
           ),
         true <-
           relay.status == :active and relay.media_ingest_id == ingest_id and
             relay.camera_source_id == owner.camera_source_id and
             relay.stream_profile_id == owner.stream_profile_id and
             not is_nil(relay.lease_expires_at) and
             DateTime.after?(relay.lease_expires_at, now) do
      {:ok, relay}
    else
      {:error, _} = error -> error
      _ -> {:error, :recorder_ingest_mismatch}
    end
  end

  defp live?(%{state: :active, lease_expires_at: %DateTime{} = expires}, now),
    do: DateTime.after?(expires, now)

  defp live?(_claim, _now), do: false
  defp publication_result(:ok), do: {:ok, :ok}
  defp publication_result({:ok, _result} = result), do: result
  defp publication_result({:error, _reason} = error), do: error
  defp publication_result(_result), do: {:error, :invalid_recording_publication_result}
  defp ttl(ms) when is_integer(ms) and ms in 1..300_000, do: :ok
  defp ttl(_ms), do: {:error, :invalid_ttl}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_recorder_identity}
    end
  end

  defp valid_ingest_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
        not String.contains?(id, <<0>>)
end
