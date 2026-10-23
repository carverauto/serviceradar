defmodule ServiceRadar.Camera.IngestOwnership do
  @moduledoc """
  Serializes camera/profile ingest ownership and independent consumer leases.

  Every operation locks the same durable owner row. Expired or released owners
  are acquired with a higher epoch, including when the token is reused. A
  takeover does not inherit consumers or a relay session from the previous epoch.
  Renewing an owner never renews consumers. Consumer expirations cannot exceed
  the owner expiration. Cleanup uses the expiry index: superseded consumers
  remain until that bounded expiration (at most five minutes after acquisition
  or renewal), without retaining or granting publication rights to the new epoch.

  Idle close reserves the current relay by moving the owner to `closing`. Late
  attaches and renewals then fail. The caller may close only the returned
  `relay_session_id`, never a subsequently discovered session. A crashed closer
  cannot strand ownership: closing expires within five seconds and can then be
  taken over. Explicit release preserves the epoch counter.

  `with_current_owner/3` fences short CNPG mutations in the same transaction as
  the ownership check. It cannot make external I/O atomic. Media objects must
  use immutable epoch-qualified keys; upload completion must re-enter this
  fence before publishing metadata, so stale workers cannot replace new media.
  Successful callbacks are checked again against database time before commit;
  writes roll back when the lease expired while the callback was running.
  """

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.StreamProfile

  require Ash.Query

  @resources [IngestOwner, ConsumerLease]
  @maximum_ttl_ms 300_000
  @close_grace_ms 5_000

  @doc "Serializes the short CNPG reservation/adoption of one camera/profile relay."
  def with_source_profile(source_id, profile_id, fun, opts \\ []) when is_function(fun, 1) do
    transaction(fn ->
      with {:ok, %StreamProfile{}} <-
             StreamProfile.get_for_relay(profile_id, source_id, caller(opts)),
           {:ok, initialized} <- initialize(source_id, profile_id, opts),
           {:ok, owner} <- lock_owner(initialized.id, opts) do
        fun.(owner)
      else
        {:ok, nil} -> {:error, :profile_unavailable}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Returns the current relay's fence handle; subsequent mutations still recheck it."
  def for_relay(relay_session_id, opts \\ []) do
    IngestOwner
    |> Ash.Query.filter(relay_session_id == ^relay_session_id and state == :active)
    |> Ash.Query.load(:database_now)
    |> Ash.read_one(caller(opts))
    |> case do
      {:ok, %IngestOwner{} = owner} ->
        if live?(owner), do: {:ok, owner}, else: {:error, :ownership_lost}

      {:ok, nil} ->
        {:error, :ownership_lost}

      {:error, _} = error ->
        error
    end
  end

  @doc "Reserves an explicit operator stop, invalidating consumer publication rights."
  def begin_close(lease, opts \\ []) do
    with_active_owner(
      lease,
      &transition(
        &1,
        %{state: :closing, lease_expires_at: consumer_expiry(&1, @close_grace_ms)},
        opts
      ),
      opts
    )
  end

  @doc "Retires a failed or closed ingest, including expired leases, without resetting its epoch."
  def retire(%{id: id, epoch: epoch, owner_token: token}, opts \\ []) do
    transaction(fn ->
      with {:ok, owner} <- lock_owner(id, opts),
           true <- owner.epoch == epoch and owner.owner_token == token do
        transition(owner, %{state: :released, lease_expires_at: owner.database_now}, opts)
      else
        false -> {:error, :ownership_lost}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Deletes one indexed batch of expired consumers, including superseded epochs."
  def prune_consumers(opts \\ []) do
    limit = Keyword.get(opts, :batch_size, 200)

    if is_integer(limit) and limit in 1..500 do
      query =
        ConsumerLease
        |> Ash.Query.filter(expires_at <= fragment("statement_timestamp()"))
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(limit)

      with {:ok, consumers} <- Ash.read(query, caller(opts)) do
        result =
          Enum.reduce(consumers, %{deleted: 0, skipped: 0, failed: 0}, fn consumer, acc ->
            case prune_consumer(consumer, opts) do
              :ok -> Map.update!(acc, :deleted, &(&1 + 1))
              {:ok, :skipped} -> Map.update!(acc, :skipped, &(&1 + 1))
              {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
            end
          end)

        {:ok, result}
      end
    else
      {:error, :invalid_batch_size}
    end
  end

  @doc "Claims a camera/profile, or renews the same still-active owner token."
  def acquire(source_id, profile_id, owner_token, ttl_ms, opts \\ []) do
    with :ok <- valid_ttl(ttl_ms),
         {:ok, token} <- uuid(owner_token) do
      transaction(fn ->
        with {:ok, %StreamProfile{}} <-
               StreamProfile.get_for_relay(profile_id, source_id, lookup(opts)),
             {:ok, initialized} <- initialize(source_id, profile_id, opts),
             {:ok, owner} <- lock_owner(initialized.id, opts) do
          claim(owner, token, ttl_ms, opts)
        else
          {:ok, nil} -> {:error, :profile_unavailable}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Renews a current owner without changing any consumer expiration."
  def renew(lease, ttl_ms, opts \\ []) do
    with :ok <- valid_ttl(ttl_ms) do
      with_active_owner(
        lease,
        &transition(&1, %{lease_expires_at: renewed_expiry(&1, ttl_ms)}, opts),
        opts
      )
    end
  end

  @doc "Binds the epoch to one existing relay session for this camera/profile."
  def bind_relay(lease, relay_session_id, opts \\ []) do
    with_active_owner(
      lease,
      fn owner ->
        with :ok <- unbound_or_same(owner, relay_session_id),
             {:ok, relay} <- RelaySession.get_by_id(relay_session_id, lookup(opts)),
             :ok <- matching_relay(owner, relay) do
          transition(owner, %{relay_session_id: relay_session_id}, opts)
        end
      end,
      opts
    )
  end

  @doc "Acquires an independently expiring consumer in the current epoch."
  def acquire_consumer(lease, kind, consumer_key, ttl_ms, opts \\ []) do
    with :ok <- valid_ttl(ttl_ms) do
      with_active_owner(
        lease,
        fn owner ->
          ConsumerLease
          |> Ash.Changeset.for_create(:acquire, %{
            ingest_owner_id: owner.id,
            owner_epoch: owner.epoch,
            kind: kind,
            consumer_key: consumer_key,
            expires_at: consumer_expiry(owner, ttl_ms)
          })
          |> Ash.create(Keyword.put(caller(opts), :load, [:database_now]))
        end,
        opts
      )
    end
  end

  @doc """
  Acquires or renews a consumer set in bounded SQL batches under one live fence.

  Used by the authoritative viewer registry at heartbeat cadence. Total work is
  proportional to admitted viewers, but each statement is limited to 256 rows;
  no per-viewer owner locks or receipt loads are needed. The final database-time
  check rolls all batches back if the owner expires during the transaction.
  """
  def acquire_consumers(lease, kind, consumer_keys, ttl_ms, opts \\ [])
      when is_list(consumer_keys) do
    with :ok <- valid_ttl(ttl_ms) do
      with_current_owner(
        lease,
        fn owner ->
          expiry = consumer_expiry(owner, ttl_ms)

          rows =
            consumer_keys
            |> Stream.uniq()
            |> Stream.map(fn key ->
              %{
                ingest_owner_id: owner.id,
                owner_epoch: owner.epoch,
                kind: kind,
                consumer_key: key,
                expires_at: expiry
              }
            end)

          case Ash.bulk_create(rows, ConsumerLease, :acquire,
                 actor: Keyword.get(opts, :actor),
                 batch_size: 256,
                 transaction: :all,
                 max_concurrency: 0,
                 return_records?: false,
                 return_errors?: true,
                 stop_on_error?: true,
                 upsert?: true,
                 upsert_identity: :consumer,
                 upsert_fields: [:expires_at]
               ) do
            %Ash.BulkResult{status: :success} -> :ok
            %Ash.BulkResult{errors: errors} -> {:error, errors || :consumer_sync_failed}
          end
        end,
        opts
      )
    end
  end

  @doc "Renews a live consumer; an expired consumer must be acquired again."
  def renew_consumer(lease, consumer_id, ttl_ms, opts \\ []) do
    with :ok <- valid_ttl(ttl_ms) do
      with_active_owner(
        lease,
        fn owner ->
          with {:ok, consumer} <- fetch_consumer(owner, consumer_id, opts),
               true <- DateTime.after?(consumer.expires_at, owner.database_now) do
            consumer
            |> Ash.Changeset.for_update(:renew, %{expires_at: consumer_expiry(owner, ttl_ms)})
            |> Ash.update(Keyword.put(caller(opts), :load, [:database_now]))
          else
            false -> {:error, :consumer_expired}
            {:error, _} = error -> error
          end
        end,
        opts
      )
    end
  end

  @doc "Releases only the named consumer; other consumers are unaffected."
  def release_consumer(lease, consumer_id, opts \\ []) do
    with_active_owner(
      lease,
      fn owner ->
        case fetch_consumer(owner, consumer_id, opts) do
          {:ok, consumer} -> Ash.destroy(consumer, caller(opts))
          {:error, :consumer_unavailable} -> :ok
          {:error, _} = error -> error
        end
      end,
      opts
    )
  end

  @doc "Atomically reserves idle close, returning the captured relay identity."
  def begin_idle_close(lease, opts \\ []) do
    with_active_owner(
      lease,
      fn owner ->
        with :ok <- require_idle(owner, opts) do
          transition(
            owner,
            %{state: :closing, lease_expires_at: consumer_expiry(owner, @close_grace_ms)},
            opts
          )
        end
      end,
      opts
    )
  end

  @doc "Releases an idle active or closing owner; epoch history is retained."
  def release(lease, opts \\ []) do
    transaction(fn ->
      with {:ok, owner} <- lock_current(lease, [:active, :closing], opts),
           :ok <- require_idle(owner, opts) do
        transition(owner, %{state: :released, lease_expires_at: owner.database_now}, opts)
      end
    end)
  end

  @doc "Runs short CNPG work under the current epoch's transaction fence."
  def with_current_owner(lease, fun, opts \\ []) when is_function(fun, 1) do
    transaction(fn ->
      with {:ok, owner} <- lock_current(lease, [:active], opts),
           {:ok, result} <- publication_result(fun.(owner)),
           {:ok, current} <-
             IngestOwner
             |> Ash.Query.filter(id == ^owner.id)
             |> Ash.Query.load(:database_now)
             |> Ash.read_one(caller(opts)),
           {:ok, _owner} <- require_current(owner, current, [:active]) do
        result
      end
    end)
  end

  defp with_active_owner(lease, fun, opts) do
    transaction(fn ->
      with {:ok, owner} <- lock_current(lease, [:active], opts), do: fun.(owner)
    end)
  end

  defp prune_consumer(consumer, opts) do
    transaction(fn ->
      with {:ok, owner} <- lock_owner(consumer.ingest_owner_id, opts),
           {:ok, current} <-
             Ash.get(
               ConsumerLease,
               consumer.id,
               Keyword.put(caller(opts), :not_found_error?, false)
             ) do
        cond do
          is_nil(current) ->
            {:ok, :skipped}

          current.owner_epoch != owner.epoch or
              not DateTime.after?(current.expires_at, owner.database_now) ->
            Ash.destroy(current, caller(opts))

          true ->
            {:ok, :skipped}
        end
      end
    end)
  end

  defp publication_result(:ok), do: {:ok, :ok}
  defp publication_result({:ok, _} = result), do: {:ok, result}
  defp publication_result({:error, _} = error), do: error
  defp publication_result(_result), do: {:error, :invalid_publication_result}

  defp initialize(source_id, profile_id, opts) do
    IngestOwner
    |> Ash.Changeset.for_create(:initialize, %{
      camera_source_id: source_id,
      stream_profile_id: profile_id
    })
    |> Ash.create(caller(opts))
  end

  defp lock_owner(id, opts) do
    with {:ok, owner} <-
           IngestOwner
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(caller(opts)) do
      case owner do
        nil -> {:error, :owner_unavailable}
        owner -> Ash.load(owner, :database_now, caller(opts))
      end
    end
  end

  defp lock_current(%{id: id} = lease, states, opts) do
    with {:ok, owner} <- lock_owner(id, opts) do
      require_current(lease, owner, states)
    end
  end

  defp lock_current(_lease, _states, _opts), do: {:error, :ownership_lost}

  defp require_current(%{epoch: epoch, owner_token: token}, %IngestOwner{} = owner, states) do
    if owner.epoch == epoch and owner.owner_token == token and owner.state in states and
         live?(owner),
       do: {:ok, owner},
       else: {:error, :ownership_lost}
  end

  defp require_current(_lease, _owner, _states), do: {:error, :ownership_lost}

  defp claim(owner, token, ttl_ms, opts) do
    cond do
      owner.state == :active and owner.owner_token == token and live?(owner) ->
        transition(owner, %{lease_expires_at: renewed_expiry(owner, ttl_ms)}, opts)

      owner.state == :released or not live?(owner) ->
        transition(
          owner,
          %{
            epoch: owner.epoch + 1,
            owner_token: token,
            state: :active,
            lease_expires_at: expiry(owner, ttl_ms),
            relay_session_id: nil
          },
          opts
        )

      true ->
        {:error, :already_owned}
    end
  end

  defp transition(owner, attrs, opts) do
    epoch = owner.epoch
    token = owner.owner_token

    fence =
      if is_nil(token),
        do: expr(epoch == ^epoch and is_nil(owner_token)),
        else: expr(epoch == ^epoch and owner_token == ^token)

    owner
    |> Ash.Changeset.for_update(:transition, attrs)
    |> Ash.Changeset.filter(fence)
    |> Ash.update(Keyword.put(caller(opts), :load, [:database_now]))
  end

  defp fetch_consumer(owner, id, opts) do
    ConsumerLease
    |> Ash.Query.filter(
      id == ^id and ingest_owner_id == ^owner.id and owner_epoch == ^owner.epoch
    )
    |> Ash.read_one(caller(opts))
    |> case do
      {:ok, nil} -> {:error, :consumer_unavailable}
      result -> result
    end
  end

  defp require_idle(owner, opts) do
    ConsumerLease
    |> Ash.Query.filter(
      ingest_owner_id == ^owner.id and owner_epoch == ^owner.epoch and
        expires_at > ^owner.database_now
    )
    |> Ash.Query.limit(1)
    |> Ash.read(caller(opts))
    |> case do
      {:ok, []} -> :ok
      {:ok, [_consumer]} -> {:error, :consumers_active}
      {:error, _} = error -> error
    end
  end

  defp unbound_or_same(%{relay_session_id: nil}, _id), do: :ok
  defp unbound_or_same(%{relay_session_id: id}, id), do: :ok
  defp unbound_or_same(_owner, _id), do: {:error, :relay_already_bound}

  defp matching_relay(owner, %RelaySession{} = relay) do
    if relay.camera_source_id == owner.camera_source_id and
         relay.stream_profile_id == owner.stream_profile_id and
         relay.status in [:requested, :opening, :active] do
      :ok
    else
      {:error, :relay_mismatch}
    end
  end

  defp matching_relay(_owner, nil), do: {:error, :relay_mismatch}

  defp live?(%{lease_expires_at: nil}), do: false
  defp live?(owner), do: DateTime.after?(owner.lease_expires_at, owner.database_now)
  defp expiry(owner, ttl_ms), do: DateTime.add(owner.database_now, ttl_ms, :millisecond)

  defp consumer_expiry(owner, ttl_ms) do
    desired = expiry(owner, ttl_ms)
    if DateTime.after?(desired, owner.lease_expires_at), do: owner.lease_expires_at, else: desired
  end

  defp renewed_expiry(owner, ttl_ms) do
    desired = expiry(owner, ttl_ms)

    if DateTime.before?(desired, owner.lease_expires_at),
      do: owner.lease_expires_at,
      else: desired
  end

  defp valid_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 and ttl_ms <= @maximum_ttl_ms,
    do: :ok

  defp valid_ttl(_ttl_ms), do: {:error, :invalid_ttl}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_owner_token}
    end
  end

  defp lookup(opts), do: Keyword.put(caller(opts), :not_found_error?, false)

  defp caller(opts), do: [actor: Keyword.get(opts, :actor)]

  defp transaction(fun) do
    @resources
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :ingest_ownership,
             value: reason,
             message: "ownership refused"
           )}

        result ->
          result
      end
    end)
    |> transaction_result()
  end

  defp transaction_result({:ok, result}), do: result

  defp transaction_result({:error, %InvalidArgument{field: :ingest_ownership, value: reason}}),
    do: {:error, reason}

  defp transaction_result(
         {:error,
          %Ash.Error.Invalid{errors: [%InvalidArgument{field: :ingest_ownership, value: reason}]}}
       ),
       do: {:error, reason}

  defp transaction_result({:error, _} = error), do: error
end
