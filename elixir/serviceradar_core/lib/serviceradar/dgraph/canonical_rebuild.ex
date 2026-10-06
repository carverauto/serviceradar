defmodule ServiceRadar.Dgraph.CanonicalRebuild do
  @moduledoc """
  Chunked, resumable rebuild of Dgraph's canonical topology edges.

  A rebuild makes the stored canonical edges equal to a desired set: upsert
  every desired edge, then delete every stored canonical edge outside the set.
  It used to be a single call that issued one RPC per edge under one 300 s
  deadline, so on a large graph it timed out every run after the upserts and
  before the stale deletes.

  Now the rebuild runs as phases driven from here:

    1. **upsert**: the desired edges, in a stable order, in chunks of up to
       200 per Dgraph transaction. Each chunk is its own call with its own
       deadline and the usual retry for idempotent writes.
    2. **delete**: one read of the stored keys outside the desired set, then
       deletes in chunks of up to 200 per transaction.

  Progress lives in `platform.dgraph_canonical_rebuild_cursors` (CNPG control
  plane state). After every upsert chunk the cursor records the next chunk
  index, and on entering the delete phase it records that phase. An
  interrupted run therefore resumes where it stopped instead of rewriting
  every edge. The cursor also carries a fingerprint of the desired set. A run
  whose desired set differs ignores the cursor and starts from the first
  chunk, because chunk boundaries over a different set mean nothing. The
  delete phase needs no position: it recomputes the stale keys from Dgraph,
  and deletes are idempotent. A fully successful run deletes the cursor.

  There is no deadline over the whole rebuild; it is bounded by its chunk
  count. Callers enqueue reconciliation only after `run/3` returns `:ok`.
  """

  alias ServiceRadar.Repo

  require Logger

  @name "canonical"
  @table "platform.dgraph_canonical_rebuild_cursors"
  @chunk_size 200

  @typedoc "The Dgraph operations a rebuild drives; injectable for tests."
  @type ops :: %{
          required(:upsert) => ([map()] -> :ok | {:error, term()}),
          required(:stale_keys) => ([map()] -> {:ok, [String.t()]} | {:error, term()}),
          required(:delete) => ([String.t()] -> :ok | {:error, term()})
        }

  @doc """
  Run (or resume) a rebuild toward `edges`.

  Options: `:repo` (default `ServiceRadar.Repo`), `:chunk_size` (default 200).
  """
  @spec run([map()], ops(), keyword()) :: :ok | {:error, term()}
  def run(edges, ops, opts \\ []) when is_list(edges) and is_map(ops) do
    repo = Keyword.get(opts, :repo, Repo)
    chunk_size = Keyword.get(opts, :chunk_size, @chunk_size)
    desired = Enum.sort_by(edges, &stable_key/1)
    fingerprint = fingerprint(desired)

    with {:ok, cursor} <- load(repo, fingerprint),
         :ok <-
           upsert_phase(repo, fingerprint, cursor, Enum.chunk_every(desired, chunk_size), ops),
         :ok <- delete_phase(desired, chunk_size, ops) do
      clear(repo)
    end
  end

  @doc false
  # The persisted cursor for the rebuild, or nil. For tests and operators.
  @spec cursor(module()) :: {:ok, map() | nil} | {:error, term()}
  def cursor(repo \\ Repo) do
    case repo.query("SELECT fingerprint, phase, next_chunk FROM #{@table} WHERE name = $1", [
           @name
         ]) do
      {:ok, %{rows: [[fingerprint, phase, next_chunk]]}} ->
        {:ok, %{fingerprint: fingerprint, phase: phase, next_chunk: next_chunk}}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load(repo, fingerprint) do
    case cursor(repo) do
      {:ok, %{fingerprint: ^fingerprint} = cursor} ->
        Logger.info("Resuming Dgraph canonical rebuild",
          phase: cursor.phase,
          next_chunk: cursor.next_chunk
        )

        {:ok, cursor}

      {:ok, _none_or_other_set} ->
        {:ok, %{phase: "upsert", next_chunk: 0}}

      {:error, reason} ->
        {:error, {:rebuild_cursor, reason}}
    end
  end

  defp upsert_phase(_repo, _fingerprint, %{phase: "delete"}, _chunks, _ops), do: :ok

  defp upsert_phase(repo, fingerprint, %{next_chunk: next_chunk}, chunks, ops) do
    chunks
    |> Enum.with_index()
    |> Enum.drop(next_chunk)
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      with :ok <- ops.upsert.(chunk),
           :ok <- save(repo, fingerprint, "upsert", index + 1) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> save(repo, fingerprint, "delete", 0)
      error -> error
    end
  end

  defp delete_phase(desired, chunk_size, ops) do
    with {:ok, stale} <- ops.stale_keys.(desired) do
      stale
      |> Enum.chunk_every(chunk_size)
      |> Enum.reduce_while(:ok, fn keys, :ok ->
        case ops.delete.(keys) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp save(repo, fingerprint, phase, next_chunk) do
    sql = """
    INSERT INTO #{@table} (name, fingerprint, phase, next_chunk, updated_at)
    VALUES ($1, $2, $3, $4, now() AT TIME ZONE 'utc')
    ON CONFLICT (name) DO UPDATE SET
      fingerprint = EXCLUDED.fingerprint,
      phase = EXCLUDED.phase,
      next_chunk = EXCLUDED.next_chunk,
      updated_at = EXCLUDED.updated_at
    """

    case repo.query(sql, [@name, fingerprint, phase, next_chunk]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:rebuild_cursor, reason}}
    end
  end

  defp clear(repo) do
    case repo.query("DELETE FROM #{@table} WHERE name = $1", [@name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:rebuild_cursor, reason}}
    end
  end

  # A total order over edge maps that does not depend on input order.
  defp stable_key(edge), do: :erlang.term_to_binary(edge, [:deterministic])

  defp fingerprint(desired) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(desired, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
