defmodule ServiceRadar.Observability.MtrHopAttributionBackfill do
  @moduledoc """
  Populates `target_ip` and `device_id` on existing `platform.mtr_hops` rows from
  the trace each hop belongs to.

  Rows written before `20260923120000_add_mtr_hop_target_attribution` carry NULL
  attribution. A NULL `target_ip` is therefore the work marker: this backfill is
  resumable because finishing a chunk leaves no NULLs in it, so a re-run skips it.

  ## Why this is not one UPDATE

  `mtr_hops` is a TimescaleDB hypertable. A single
  `UPDATE ... FROM mtr_traces` across every chunk is the shape that exhausts a
  compute node's memory and gets it OOM-killed, and a long statement is what
  `statement_timeout` cancels. So the work is bounded twice: chunk by chunk, and
  within a chunk by a row limit, looping until that chunk is clean.

  ## Compressed chunks

  DML against a compressed chunk works from TimescaleDB 2.11 and is verified on
  2.24. Below 2.11 it fails, so `run/1` refuses up front with the detected version
  rather than erroring part-way through a chunk and leaving the table half
  attributed. Updating a compressed chunk is slower and writes through staging,
  which is a second reason the row limit matters.

  ## Rows that can never be attributed

  A hop whose trace has already aged out of `mtr_traces` has nothing to inherit
  from. Those rows are counted and reported separately as unrecoverable rather
  than being retried forever or silently folded into the remaining count -- a
  backfill that reports "work left" it can never do is indistinguishable from one
  that is stuck.

  Dry run is the default, matching the other backfill tasks in this repository.
  """

  alias ServiceRadar.Repo

  require Logger

  @schema "platform"
  @min_timescale Version.parse!("2.11.0")
  @default_batch 10_000
  @max_batch 200_000

  @type mode :: :dry_run | :execute

  @type report :: %{
          mode: mode(),
          timescale_version: String.t() | nil,
          chunks_examined: non_neg_integer(),
          chunks_with_work: non_neg_integer(),
          rows_updated: non_neg_integer(),
          rows_remaining: non_neg_integer(),
          rows_unrecoverable: non_neg_integer()
        }

  @doc """
  Runs the backfill.

  Options:

    * `:mode` - `:dry_run` (default) or `:execute`
    * `:batch_size` - rows per statement, 1..#{@max_batch} (default #{@default_batch})
    * `:max_chunks` - stop after this many chunks that had work, for a bounded first pass
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :dry_run)
    batch_size = opts |> Keyword.get(:batch_size, @default_batch) |> clamp(1, @max_batch)
    max_chunks = Keyword.get(opts, :max_chunks)

    with {:ok, version} <- ensure_timescale_supports_dml(),
         {:ok, chunks} <- chunks() do
      report =
        Enum.reduce_while(chunks, initial_report(mode, version), fn chunk, acc ->
          acc = %{acc | chunks_examined: acc.chunks_examined + 1}

          case process_chunk(chunk, mode, batch_size) do
            {:ok, %{updated: 0, remaining: 0}} ->
              {:cont, acc}

            {:ok, %{updated: updated, remaining: remaining}} ->
              acc = %{
                acc
                | chunks_with_work: acc.chunks_with_work + 1,
                  rows_updated: acc.rows_updated + updated,
                  rows_remaining: acc.rows_remaining + remaining
              }

              if is_integer(max_chunks) and acc.chunks_with_work >= max_chunks do
                {:halt, acc}
              else
                {:cont, acc}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case report do
        {:error, reason} -> {:error, reason}
        report -> {:ok, %{report | rows_unrecoverable: count_unrecoverable()}}
      end
    end
  end

  defp initial_report(mode, version) do
    %{
      mode: mode,
      timescale_version: version,
      chunks_examined: 0,
      chunks_with_work: 0,
      rows_updated: 0,
      rows_remaining: 0,
      rows_unrecoverable: 0
    }
  end

  # A hop can only be attributed if its trace is still present. Counting the
  # recoverable work separately from the unrecoverable is what keeps a re-run from
  # looking stuck on rows it can never fix.
  defp process_chunk(chunk, mode, batch_size) do
    case pending_in_chunk(chunk) do
      {:ok, 0} ->
        {:ok, %{updated: 0, remaining: 0}}

      {:ok, pending} when mode == :dry_run ->
        {:ok, %{updated: 0, remaining: pending}}

      {:ok, _pending} ->
        drain_chunk(chunk, batch_size, 0)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drain_chunk(chunk, batch_size, updated_so_far) do
    case update_batch(chunk, batch_size) do
      {:ok, 0} ->
        {:ok, %{updated: updated_so_far, remaining: 0}}

      {:ok, n} ->
        drain_chunk(chunk, batch_size, updated_so_far + n)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @dialyzer {:nowarn_function, update_batch: 2}
  defp update_batch(chunk, batch_size) do
    sql = """
    UPDATE #{@schema}.mtr_hops AS h
       SET target_ip = t.target_ip,
           device_id = t.device_id
      FROM #{@schema}.mtr_traces AS t
     WHERE h.trace_id = t.id
       AND h.target_ip IS NULL
       AND (h."time", h.id) IN (
             SELECT inner_h."time", inner_h.id
               FROM #{@schema}.mtr_hops AS inner_h
               JOIN #{@schema}.mtr_traces AS inner_t ON inner_t.id = inner_h.trace_id
              WHERE inner_h.target_ip IS NULL
                AND inner_h."time" >= $1
                AND inner_h."time" < $2
              LIMIT $3
           )
    """

    case Repo.query(sql, [chunk.range_start, chunk.range_end, batch_size]) do
      {:ok, %{num_rows: n}} -> {:ok, n}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending_in_chunk(chunk) do
    sql = """
    SELECT count(*)
      FROM #{@schema}.mtr_hops AS h
      JOIN #{@schema}.mtr_traces AS t ON t.id = h.trace_id
     WHERE h.target_ip IS NULL
       AND h."time" >= $1
       AND h."time" < $2
    """

    case Repo.query(sql, [chunk.range_start, chunk.range_end]) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # Hops whose trace is gone. Reported, never retried.
  defp count_unrecoverable do
    sql = """
    SELECT count(*)
      FROM #{@schema}.mtr_hops AS h
     WHERE h.target_ip IS NULL
       AND NOT EXISTS (
             SELECT 1 FROM #{@schema}.mtr_traces AS t WHERE t.id = h.trace_id
           )
    """

    case Repo.query(sql, []) do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _reason} -> 0
    end
  end

  # Newest first: the most recently traced data is what a dashboard reads, so a
  # partial backfill is immediately useful rather than useful only once complete.
  defp chunks do
    sql = """
    SELECT range_start, range_end
      FROM timescaledb_information.chunks
     WHERE hypertable_schema = $1
       AND hypertable_name = 'mtr_hops'
     ORDER BY range_start DESC
    """

    case Repo.query(sql, [@schema]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [s, e] -> %{range_start: s, range_end: e} end)}

      {:error, reason} ->
        {:error, {:chunk_enumeration_failed, reason}}
    end
  end

  defp ensure_timescale_supports_dml do
    case Repo.query("SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'", []) do
      {:ok, %{rows: [[raw]]}} when is_binary(raw) ->
        case Version.parse(normalize_version(raw)) do
          {:ok, version} ->
            if Version.compare(version, @min_timescale) == :lt do
              {:error,
               {:timescale_too_old,
                "TimescaleDB #{raw} does not support DML on compressed chunks; " <>
                  "#{@min_timescale} or newer is required"}}
            else
              {:ok, raw}
            end

          :error ->
            {:error, {:timescale_version_unparsable, raw}}
        end

      {:ok, %{rows: []}} ->
        {:error, :timescale_not_installed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_version(raw) do
    case String.split(raw, ".") do
      [major] -> "#{major}.0.0"
      [major, minor] -> "#{major}.#{minor}.0"
      [major, minor, patch | _] -> "#{major}.#{minor}.#{patch}"
    end
  end

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, min, _max), do: min
end
