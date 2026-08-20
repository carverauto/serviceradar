defmodule ServiceRadar.Repo.Migrations.BackfillCanonicalOtelIds do
  @moduledoc """
  One-time backfill normalizing legacy OTel identifiers to the canonical
  contract (trace_id = 32-char lowercase hex, span_id/parent_span_id =
  16-char lowercase hex, absent/zero → NULL):

  - `logs.trace_id`/`logs.span_id` double-hex rows (the Erlang OTLP logs
    exporter put ASCII hex into protobuf bytes fields; consumers hexed the
    text once more) are decoded back to canonical hex.
  - Uppercase hex is downcased.
  - Empty strings, all-zero ids, and remaining non-canonical values become
    NULL (`otel_traces.trace_id`/`span_id` are PK columns and keep their
    values; only `parent_span_id` is normalized there).

  All updates run in bounded batches outside a single wrapping transaction
  so the backfill cannot hold long locks on live hypertables.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 50_000

  def up do
    # --- logs: downcase any uppercase hex ids (any supported length) ---
    batched_logs_update(
      "trace_id",
      "lower(trace_id)",
      "trace_id ~ '^[0-9A-Fa-f]+$' AND trace_id ~ '[A-F]'"
    )

    batched_logs_update(
      "span_id",
      "lower(span_id)",
      "span_id ~ '^[0-9A-Fa-f]+$' AND span_id ~ '[A-F]'"
    )

    # --- logs: fold double-hex ids (64 -> 32 chars / 32 -> 16 chars) ---
    batched_logs_update(
      "trace_id",
      "convert_from(decode(trace_id, 'hex'), 'UTF8')",
      """
      length(trace_id) = 64
        AND trace_id ~ '^[0-9a-f]{64}$'
        AND convert_from(decode(trace_id, 'hex'), 'UTF8') ~ '^[0-9a-f]{32}$'
      """
    )

    batched_logs_update(
      "span_id",
      "convert_from(decode(span_id, 'hex'), 'UTF8')",
      """
      length(span_id) = 32
        AND span_id ~ '^[0-9a-f]{32}$'
        AND convert_from(decode(span_id, 'hex'), 'UTF8') ~ '^[0-9a-f]{16}$'
      """
    )

    # --- logs: zero ids -> NULL ---
    batched_logs_update("trace_id", "NULL", "trace_id = repeat('0', 32)")
    batched_logs_update("span_id", "NULL", "span_id = repeat('0', 16)")

    # --- logs: anything still non-canonical (including '') -> NULL ---
    batched_logs_update(
      "trace_id",
      "NULL",
      "trace_id IS NOT NULL AND trace_id !~ '^[0-9a-f]{32}$'"
    )

    batched_logs_update(
      "span_id",
      "NULL",
      "span_id IS NOT NULL AND span_id !~ '^[0-9a-f]{16}$'"
    )

    # --- otel_traces / derived tables: ONE-TIME RESET instead of row-wise
    #     normalization. Pre-canonical span data is definitionally
    #     uncorrelatable (the very bug this change fixes), trace summaries
    #     and span samples are derived from it, and short retention would
    #     purge it within days anyway. A row-wise parent_span_id backfill
    #     measured ~2 hours on a ~16M-row live hypertable; nothing predating
    #     the canonical-ID contract is worth that. Post-reset writers only
    #     ever produce canonical ids, so no future migration needs this.
    execute("""
    TRUNCATE #{schema()}.otel_traces,
             #{schema()}.otel_trace_summaries,
             #{schema()}.otel_metrics
    """)
  end

  def down do
    # Lossy one-time backfill; nothing to restore.
    :ok
  end

  defp batched_logs_update(column, expression, condition) do
    sql = """
    UPDATE #{schema()}.logs
    SET #{column} = #{expression}
    WHERE id IN (
      SELECT id
      FROM #{schema()}.logs
      WHERE #{condition}
      LIMIT #{@batch_size}
    )
    AND (#{condition})
    """

    run_batches(sql)
  end

  defp run_batches(sql) do
    case query_num_rows(sql) do
      {:ok, num_rows} when num_rows >= @batch_size -> run_batches(sql)
      {:ok, _num_rows} -> :ok
      :missing_table -> :ok
    end
  end

  defp query_num_rows(sql) do
    case repo().query(sql, [], timeout: 600_000) do
      {:ok, %{num_rows: num_rows}} ->
        {:ok, num_rows}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :missing_table

      {:error, error} ->
        raise error
    end
  end

  defp schema, do: prefix() || "platform"
end
