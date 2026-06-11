defmodule ServiceRadar.Repo.Migrations.AddOtelIdCheckConstraints do
  @moduledoc """
  Enforces the canonical OTel identifier contract at the schema level:
  trace_id = 32-char lowercase hex, span_id/parent_span_id = 16-char
  lowercase hex, NULL allowed (absent ids).

  Constraints are created NOT VALID (instantly enforced for new writes)
  and then validated. If legacy rows still violate the contract the
  VALIDATE step logs a notice and leaves the constraint NOT VALID — new
  ingest stays protected and the validation can be re-run after another
  backfill pass.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @constraints [
    {"logs", "chk_logs_trace_id_canonical", "trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'"},
    {"logs", "chk_logs_span_id_canonical", "span_id IS NULL OR span_id ~ '^[0-9a-f]{16}$'"},
    {"otel_traces", "chk_otel_traces_trace_id_canonical",
     "trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'"},
    {"otel_traces", "chk_otel_traces_span_id_canonical",
     "span_id IS NULL OR span_id ~ '^[0-9a-f]{16}$'"},
    {"otel_traces", "chk_otel_traces_parent_span_id_canonical",
     "parent_span_id IS NULL OR parent_span_id ~ '^[0-9a-f]{16}$'"}
  ]

  def up do
    Enum.each(@constraints, fn {table, name, check} ->
      add_constraint(table, name, check)
    end)

    Enum.each(@constraints, fn {table, name, _check} ->
      validate_constraint(table, name)
    end)
  end

  def down do
    Enum.each(@constraints, fn {table, name, _check} ->
      execute("""
      ALTER TABLE #{schema()}.#{table}
      DROP CONSTRAINT IF EXISTS #{name}
      """)
    end)
  end

  defp add_constraint(table, name, check) do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{schema()}.#{table}') IS NULL THEN
        RAISE NOTICE 'Table #{schema()}.#{table} missing; skipping constraint #{name}';
        RETURN;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = '#{schema()}'
          AND t.relname = '#{table}'
          AND c.conname = '#{name}'
      ) THEN
        ALTER TABLE #{schema()}.#{table}
          ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID;
      END IF;
    END;
    $$;
    """)
  end

  defp validate_constraint(table, name) do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{schema()}.#{table}') IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        ALTER TABLE #{schema()}.#{table} VALIDATE CONSTRAINT #{name};
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not validate #{name} on #{schema()}.#{table}: % (constraint stays NOT VALID; new writes are still checked)', SQLERRM;
      END;
    END;
    $$;
    """)
  end

  defp schema, do: prefix() || "platform"
end
