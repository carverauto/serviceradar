defmodule ServiceRadar.Automation.Ansible.AwxInventoryObservationFence do
  @moduledoc """
  Orders AWX controller observations independently of membership authority.

  One plugin aggregate covers every inventory visible to a controller. Both
  partial and complete-empty aggregates advance this watermark. The locked
  check and advance belong to the membership transaction, so a failed write
  cannot acknowledge an observation that did not finish reconciling.
  """

  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Repo

  @table "platform.ansible_awx_inventory_observations"

  @type superseded :: {:stale_awx_membership_generation, String.t(), integer(), integer()}

  @doc """
  Runs `fun` in one transaction holding every aggregate's observation lock.

  An aggregate older than its controller's recorded generation is superseded:
  a newer observation already committed, and the generation only advances, so
  no later delivery of it can be applied. When every aggregate is already
  superseded according to the committed watermark, `with_locks/3` returns
  `{:ok, {:superseded, reasons}}` immediately without opening a transaction,
  waiting on the controller advisory lock, or running `fun`, so redeliveries
  settle instead of forming an advisory-lock convoy behind an active ingest.
  Otherwise it acquires each controller lock in sorted order and re-checks the
  watermark inside the transaction. Any other refusal, and a superseded
  aggregate beside one that is not, is an error. Notifications and side effects
  queued on `ServiceRadar.Ash.NotificationQueue` inside `fun` are sent once the
  transaction commits.
  """
  @spec with_locks([map()], (-> {:ok, result} | {:error, term()}), keyword()) ::
          {:ok, result} | {:ok, {:superseded, [superseded(), ...]}} | {:error, term()}
        when result: term()
  def with_locks(aggregates, fun, opts \\ []) do
    read_fn = Keyword.get(opts, :read, &read/1)
    lock_fn = Keyword.get(opts, :lock, &lock_controller/1)
    rollback_fn = Keyword.get(opts, :rollback, &Repo.rollback/1)
    sorted = Enum.sort_by(aggregates, & &1.controller_id)

    # The ingestion transaction owns the notification queue: device hints and Ash
    # notifications raised by the writers inside it are sent once it commits and
    # dropped if it rolls back, never at an inner savepoint.
    transaction_fn =
      Keyword.get(opts, :transaction, fn tx_fun ->
        NotificationQueue.with_queue(fn -> Repo.transaction(tx_fun, timeout: :infinity) end)
      end)

    case precheck_superseded(sorted, read_fn) do
      {:superseded, reasons} ->
        {:ok, {:superseded, reasons}}

      :proceed ->
        transaction_fn.(fn ->
          case lock_and_admit(sorted, lock_fn, read_fn) do
            :ok -> run_admitted(fun, rollback_fn)
            {:superseded, reasons} -> {:superseded, reasons}
            {:error, reason} -> rollback_fn.(reason)
          end
        end)
    end
  end

  defp precheck_superseded([], _read_fn), do: :proceed

  defp precheck_superseded(aggregates, read_fn) do
    aggregates
    |> Enum.reduce_while([], fn aggregate, superseded ->
      case check(aggregate, read_fn) do
        {:error, {:stale_awx_membership_generation, _, _, _} = reason} ->
          {:cont, [reason | superseded]}

        _other ->
          {:halt, :proceed}
      end
    end)
    |> case do
      :proceed -> :proceed
      superseded -> {:superseded, Enum.reverse(superseded)}
    end
  end

  defp run_admitted(fun, rollback_fn) do
    case fun.() do
      {:ok, result} -> result
      {:error, reason} -> rollback_fn.(reason)
    end
  end

  defp lock_and_admit(aggregates, lock_fn, read_fn) do
    aggregates
    |> Enum.reduce_while([], fn aggregate, checks ->
      case lock_and_check(aggregate, lock_fn, read_fn) do
        {:error, {:stale_awx_membership_generation, _, _, _}} = check -> {:cont, [check | checks]}
        {:error, _reason} = error -> {:halt, error}
        {:ok, _disposition} = check -> {:cont, [check | checks]}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      checks -> admission(Enum.reverse(checks))
    end
  end

  @doc false
  def admission(checks) do
    case for({:error, reason} <- checks, do: reason) do
      [] -> :ok
      superseded when length(superseded) == length(checks) -> {:superseded, superseded}
      [reason | _] -> {:error, reason}
    end
  end

  def check(aggregate, read_fn \\ &read/1) do
    case read_fn.(aggregate.controller_id) do
      {:ok, current} -> disposition(aggregate, current)
      {:error, _} = error -> error
    end
  end

  def lock_and_check(aggregate, lock_fn \\ &lock_controller/1, read_fn \\ &read/1) do
    with :ok <- lock_fn.(aggregate.controller_id) do
      check(aggregate, read_fn)
    end
  end

  @doc """
  Takes the controller's observation lock for the rest of the current
  transaction. Membership reconciliation holds it while it reads and writes a
  controller's memberships; any other membership writer that must not
  interleave with reconciliation takes it too.
  """
  @spec lock_controller(String.t()) :: :ok | {:error, term()}
  def lock_controller(controller_id) when is_binary(controller_id) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           "awx-inventory-observation:" <> controller_id
         ]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  def disposition(_aggregate, nil), do: {:ok, :initial}

  def disposition(aggregate, current) do
    cond do
      aggregate.source_generation < current.source_generation ->
        {:error,
         {:stale_awx_membership_generation, aggregate.controller_id, aggregate.source_generation,
          current.source_generation}}

      aggregate.source_generation == current.source_generation ->
        if digest(aggregate) == current.observation_digest,
          do: {:ok, :replay},
          else:
            {:error,
             {:conflicting_awx_inventory_observation, aggregate.controller_id,
              aggregate.source_generation}}

      true ->
        {:ok, :advance}
    end
  end

  def advance(aggregate) do
    statement = """
    INSERT INTO #{@table} AS current
      (controller_id, source_generation, source_fingerprint, observation_digest,
       observed_at, complete, inserted_at, updated_at)
    VALUES (($1::text)::uuid, $2, $3, $4, $5, $6, now(), now())
    ON CONFLICT (controller_id) DO UPDATE SET
      source_generation = EXCLUDED.source_generation,
      source_fingerprint = EXCLUDED.source_fingerprint,
      observation_digest = EXCLUDED.observation_digest,
      observed_at = EXCLUDED.observed_at,
      complete = EXCLUDED.complete,
      updated_at = now()
    WHERE current.source_generation < EXCLUDED.source_generation
       OR (current.source_generation = EXCLUDED.source_generation
           AND current.observation_digest = EXCLUDED.observation_digest)
    """

    case Repo.query(statement, [
           aggregate.controller_id,
           aggregate.source_generation,
           aggregate.source_fingerprint,
           digest(aggregate),
           DateTime.to_naive(aggregate.observed_at),
           aggregate.complete
         ]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :awx_inventory_observation_conflict}
      {:error, _} = error -> error
    end
  end

  @doc false
  def digest(aggregate) do
    aggregate
    |> Map.take([:controller_id, :source_generation, :source_fingerprint, :complete, :hosts])
    |> Map.update!(
      :hosts,
      &Enum.sort_by(&1, fn host -> {host.inventory_id, host.awx_host_id} end)
    )
    |> Map.put(:observed_at, DateTime.to_iso8601(aggregate.observed_at))
    |> Map.put(:collection_id, aggregate.collection_id)
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp read(controller_id) do
    case Repo.query(
           "SELECT source_generation, observation_digest FROM #{@table} WHERE controller_id = ($1::text)::uuid",
           [controller_id]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[generation, digest]]}} ->
        {:ok, %{source_generation: generation, observation_digest: digest}}

      {:error, _} = error ->
        error
    end
  end
end
