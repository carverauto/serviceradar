defmodule ServiceRadar.Repo.Migrations.BackfillCanonicalBmpRoutingAddresses do
  @moduledoc """
  Rewrites the display/query projection of legacy BMP rows whose IPv4 addresses
  were rendered as IPv4-mapped IPv6 values by the JSON collector publisher.

  `raw_data` intentionally remains byte-for-byte unchanged: it is the original
  producer payload and is retained for forensic replay. The derived columns and
  normalized metadata are the user-facing projection and can be repaired without
  changing that source evidence.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - the BMP table has a short retention
  # policy and this repair is bounded to 10,000 row-level locks per transaction
  # with SKIP LOCKED. It is a no-op on fresh installs, preserves raw_data, and is
  # idempotent so a retry after an interrupted upgrade safely resumes the repair.
  @disable_ddl_transaction true

  @batch_size 10_000
  @table "bmp_routing_events"
  @trigger "serviceradar_canonical_bmp_routing_addresses"

  def up do
    schema = schema()

    Enum.each(helper_statements(schema), &execute/1)
    # The Helm schema job runs before the new core Deployment rolls out, so old
    # EventWriter pods can still write mapped projections while this migration
    # is running. Install this database barrier before the batch repair so a
    # legacy write cannot slip past a completed batch during the rollout.
    Enum.each(trigger_statements(schema), &execute/1)
    flush()

    backfill_batches(
      repo(),
      backfill_batch_sql(schema, @table, @batch_size, :skip_locked),
      backfill_batch_sql(schema, @table, @batch_size, :wait),
      @batch_size
    )
  end

  def down do
    # The forward repair is deliberately idempotent but not reversible: the old
    # mapped representation is a lossy UI defect, not authoritative raw data.
    schema = schema()

    Enum.each(drop_trigger_statements(schema), &execute/1)
    flush()
    Enum.each(drop_helper_statements(schema), &execute/1)
    flush()
  end

  @doc false
  def helper_statements(schema) do
    [
      """
      CREATE OR REPLACE FUNCTION #{schema}.serviceradar_canonical_bmp_value(value text)
      RETURNS text
      LANGUAGE sql
      IMMUTABLE
      PARALLEL SAFE
      AS $$
        SELECT CASE
          WHEN value ~* '^::ffff:((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(/(3[0-2]|[12]?[0-9]))?$'
            THEN substring(value FROM 8)
          ELSE value
        END
      $$
      """,
      """
      CREATE OR REPLACE FUNCTION #{schema}.serviceradar_canonical_bmp_json_path(
        value jsonb,
        path text[]
      )
      RETURNS jsonb
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      DECLARE
        original_value text;
        canonical_value text;
        parent_value jsonb;
      BEGIN
        IF jsonb_typeof(value) <> 'object' THEN
          RETURN value;
        END IF;

        parent_value := value #> path[1:array_length(path, 1) - 1];

        IF jsonb_typeof(parent_value) <> 'object' THEN
          RETURN value;
        END IF;

        original_value := value #>> path;

        IF original_value IS NULL THEN
          RETURN value;
        END IF;

        canonical_value := #{schema}.serviceradar_canonical_bmp_value(original_value);

        IF canonical_value IS NOT DISTINCT FROM original_value THEN
          RETURN value;
        END IF;

        RETURN jsonb_set(value, path, to_jsonb(canonical_value), false);
      END
      $$
      """,
      """
      CREATE OR REPLACE FUNCTION #{schema}.serviceradar_canonical_bmp_json_array(
        value jsonb,
        path text[]
      )
      RETURNS jsonb
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      DECLARE
        current_value jsonb;
        normalized_value jsonb;
        parent_value jsonb;
      BEGIN
        IF jsonb_typeof(value) <> 'object' THEN
          RETURN value;
        END IF;

        parent_value := value #> path[1:array_length(path, 1) - 1];

        IF jsonb_typeof(parent_value) <> 'object' THEN
          RETURN value;
        END IF;

        current_value := value #> path;

        IF jsonb_typeof(current_value) <> 'array' THEN
          RETURN value;
        END IF;

        SELECT COALESCE(
          jsonb_agg(
            CASE
              WHEN jsonb_typeof(entry.value) = 'string'
                THEN to_jsonb(
                  #{schema}.serviceradar_canonical_bmp_value(entry.value #>> '{}')
                )
              ELSE entry.value
            END
            ORDER BY entry.ordinality
          ),
          '[]'::jsonb
        )
        INTO normalized_value
        FROM jsonb_array_elements(current_value) WITH ORDINALITY AS entry(value, ordinality);

        IF normalized_value = current_value THEN
          RETURN value;
        END IF;

        RETURN jsonb_set(value, path, normalized_value, false);
      END
      $$
      """,
      """
      CREATE OR REPLACE FUNCTION #{schema}.serviceradar_canonical_bmp_metadata(value jsonb)
      RETURNS jsonb
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      DECLARE
        normalized jsonb;
      BEGIN
        IF value IS NULL THEN
          RETURN NULL;
        END IF;

        normalized := value;

        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['source_identity', 'router_ip']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['source_identity', 'peer_ip']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['routing_correlation', 'router_id']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['routing_correlation', 'router_ip']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['routing_correlation', 'peer_ip']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_path(
          normalized,
          ARRAY['routing_correlation', 'prefix']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_array(
          normalized,
          ARRAY['routing_correlation', 'topology_keys']
        );
        normalized := #{schema}.serviceradar_canonical_bmp_json_array(
          normalized,
          ARRAY['explainability', 'routing_topology_keys']
        );

        RETURN normalized;
      END
      $$
      """
    ]
  end

  @doc false
  def drop_helper_statements(schema) do
    [
      "DROP FUNCTION IF EXISTS #{schema}.serviceradar_canonical_bmp_metadata(jsonb)",
      "DROP FUNCTION IF EXISTS #{schema}.serviceradar_canonical_bmp_json_array(jsonb, text[])",
      "DROP FUNCTION IF EXISTS #{schema}.serviceradar_canonical_bmp_json_path(jsonb, text[])",
      "DROP FUNCTION IF EXISTS #{schema}.serviceradar_canonical_bmp_value(text)"
    ]
  end

  @doc false
  def trigger_statements(schema, table \\ @table) do
    [
      """
      CREATE OR REPLACE FUNCTION #{schema}.serviceradar_canonical_bmp_routing_projection()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        NEW.router_id := #{schema}.serviceradar_canonical_bmp_value(NEW.router_id);
        NEW.router_ip := #{schema}.serviceradar_canonical_bmp_value(NEW.router_ip);
        NEW.peer_ip := #{schema}.serviceradar_canonical_bmp_value(NEW.peer_ip);
        NEW.prefix := #{schema}.serviceradar_canonical_bmp_value(NEW.prefix);

        -- Avoid allocating/re-writing JSONB when it cannot contain a mapped value.
        IF NEW.metadata IS NOT NULL AND NEW.metadata::text ~* '::ffff:' THEN
          NEW.metadata := #{schema}.serviceradar_canonical_bmp_metadata(NEW.metadata);
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        DROP TRIGGER IF EXISTS #{@trigger} ON #{schema}.#{table};
        CREATE TRIGGER #{@trigger}
        BEFORE INSERT OR UPDATE ON #{schema}.#{table}
        FOR EACH ROW
        EXECUTE FUNCTION #{schema}.serviceradar_canonical_bmp_routing_projection();
      END
      $$
      """
    ]
  end

  @doc false
  def drop_trigger_statements(schema, table \\ @table) do
    [
      "DROP TRIGGER IF EXISTS #{@trigger} ON #{schema}.#{table}",
      "DROP FUNCTION IF EXISTS #{schema}.serviceradar_canonical_bmp_routing_projection()"
    ]
  end

  @doc false
  def backfill_batch_sql(
        schema,
        table \\ @table,
        batch_size \\ @batch_size,
        lock_mode \\ :skip_locked
      ) do
    lock_clause = lock_clause(lock_mode)

    """
    WITH candidates AS (
      SELECT time, id
      FROM #{schema}.#{table} AS event
      WHERE event.router_id IS DISTINCT FROM #{schema}.serviceradar_canonical_bmp_value(event.router_id)
         OR event.router_ip IS DISTINCT FROM #{schema}.serviceradar_canonical_bmp_value(event.router_ip)
         OR event.peer_ip IS DISTINCT FROM #{schema}.serviceradar_canonical_bmp_value(event.peer_ip)
         OR event.prefix IS DISTINCT FROM #{schema}.serviceradar_canonical_bmp_value(event.prefix)
         OR event.metadata IS DISTINCT FROM #{schema}.serviceradar_canonical_bmp_metadata(event.metadata)
      ORDER BY time, id
      LIMIT #{batch_size}
      #{lock_clause}
    )
    UPDATE #{schema}.#{table} AS event
    SET router_id = #{schema}.serviceradar_canonical_bmp_value(event.router_id),
        router_ip = #{schema}.serviceradar_canonical_bmp_value(event.router_ip),
        peer_ip = #{schema}.serviceradar_canonical_bmp_value(event.peer_ip),
        prefix = #{schema}.serviceradar_canonical_bmp_value(event.prefix),
        metadata = #{schema}.serviceradar_canonical_bmp_metadata(event.metadata)
    FROM candidates
    WHERE event.time = candidates.time
      AND event.id = candidates.id
    """
  end

  @doc false
  def backfill_batches(repo, skip_locked_sql, strict_sql, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    do_skip_locked_batches(repo, skip_locked_sql, strict_sql, batch_size, 0, 0)
  end

  # `SKIP LOCKED` keeps normal batches from contending with writers. Once the
  # non-blocking pass is short, switch to a strict pass so an old row that was
  # temporarily locked cannot be silently left behind. With the same bounded
  # lock timeout, a long-held lock fails the migration (and therefore retries
  # safely) instead of recording a partial repair as complete.
  defp do_skip_locked_batches(repo, skip_locked_sql, strict_sql, batch_size, rows, batches) do
    case run_batch(repo, skip_locked_sql) do
      count when count >= batch_size ->
        do_skip_locked_batches(
          repo,
          skip_locked_sql,
          strict_sql,
          batch_size,
          rows + count,
          batches + 1
        )

      count ->
        do_strict_batches(
          repo,
          strict_sql,
          batch_size,
          rows + count,
          batches + if(count > 0, do: 1, else: 0)
        )
    end
  end

  defp do_strict_batches(repo, strict_sql, batch_size, rows, batches) do
    case run_batch(repo, strict_sql) do
      count when count >= batch_size ->
        do_strict_batches(repo, strict_sql, batch_size, rows + count, batches + 1)

      0 ->
        {:ok, %{rows: rows, batches: batches}}

      count ->
        # Execute one more strict query after a short batch. That confirms no
        # legacy projection became visible while the preceding transaction was
        # committing.
        do_strict_batches(repo, strict_sql, batch_size, rows + count, batches + 1)
    end
  end

  defp run_batch(repo, sql) do
    {:ok, count} =
      repo.transaction(
        fn ->
          repo.query!("SET LOCAL lock_timeout = '5s'")
          repo.query!("SET LOCAL statement_timeout = '60s'")

          %{num_rows: count} = repo.query!(sql, [], timeout: 65_000)
          count
        end,
        timeout: 70_000
      )

    count
  end

  defp schema, do: prefix() || "platform"

  defp lock_clause(:skip_locked), do: "FOR UPDATE SKIP LOCKED"
  defp lock_clause(:wait), do: "FOR UPDATE"
end
