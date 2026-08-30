defmodule ServiceRadar.Repo.Migrations.AddSweepGroupAgentIds do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @table "platform.sweep_groups"
  @index "sweep_groups_agent_ids_gin_idx"
  @function "platform.sweep_groups_agent_ids_compat"
  @trigger "sweep_groups_agent_ids_compat_trigger"

  def up do
    alter table(:sweep_groups, prefix: @prefix) do
      add :agent_ids, {:array, :text}
    end

    execute(backfill_bounded_sql())
    execute("ALTER TABLE #{@table} ALTER COLUMN agent_ids SET DEFAULT ARRAY[]::text[]")
    execute("ALTER TABLE #{@table} ALTER COLUMN agent_ids SET NOT NULL")
    execute("CREATE INDEX #{@index} ON #{@table} USING GIN (agent_ids)")
    execute(compatibility_function_sql())
    execute(compatibility_trigger_sql())
  end

  def down do
    execute("DROP TRIGGER IF EXISTS #{@trigger} ON #{@table}")
    execute("DROP FUNCTION IF EXISTS #{@function}()")
    execute("DROP INDEX IF EXISTS #{@prefix}.#{@index}")

    alter table(:sweep_groups, prefix: @prefix) do
      remove :agent_ids
    end
  end

  def compatibility_function_sql do
    """
    CREATE OR REPLACE FUNCTION #{@function}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF cardinality(COALESCE(NEW.agent_ids, ARRAY[]::text[])) = 0
           AND NULLIF(btrim(COALESCE(NEW.agent_id, '')), '') IS NOT NULL THEN
          NEW.agent_ids := ARRAY[btrim(NEW.agent_id)];
        END IF;
      ELSIF NEW.agent_id IS DISTINCT FROM OLD.agent_id
            AND NEW.agent_ids IS NOT DISTINCT FROM OLD.agent_ids THEN
        NEW.agent_ids := CASE
          WHEN NULLIF(btrim(COALESCE(NEW.agent_id, '')), '') IS NULL THEN ARRAY[]::text[]
          ELSE ARRAY[btrim(NEW.agent_id)]
        END;
      END IF;

      NEW.agent_ids := ARRAY(
        SELECT agent_id
        FROM (
          SELECT DISTINCT btrim(value) AS agent_id
          FROM unnest(COALESCE(NEW.agent_ids, ARRAY[]::text[])) AS value
          WHERE btrim(value) <> ''
        ) normalized
        ORDER BY agent_id
      );

      NEW.agent_id := CASE
        WHEN cardinality(NEW.agent_ids) = 0 THEN NULL
        ELSE NEW.agent_ids[1]
      END;

      RETURN NEW;
    END;
    $$
    """
  end

  def compatibility_trigger_sql(table \\ @table) do
    """
    CREATE TRIGGER #{@trigger}
    BEFORE INSERT OR UPDATE OF agent_id, agent_ids ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{@function}()
    """
  end

  def backfill_bounded_sql(table \\ @table) do
    """
    DO $$
    DECLARE
      updated_count integer;
    BEGIN
      LOOP
        UPDATE #{table}
        SET agent_ids = CASE
          WHEN NULLIF(btrim(COALESCE(agent_id, '')), '') IS NULL THEN ARRAY[]::text[]
          ELSE ARRAY[btrim(agent_id)]
        END
        WHERE ctid IN (
          SELECT ctid FROM #{table} WHERE agent_ids IS NULL LIMIT 10000
        );

        GET DIAGNOSTICS updated_count = ROW_COUNT;
        EXIT WHEN updated_count = 0;
      END LOOP;
    END;
    $$
    """
  end
end
