defmodule ServiceRadar.Repo.Migrations.KeepMultiAgentSweepAssignment do
  @moduledoc """
  A scalar `agent_id` write must not replace a multi-agent `agent_ids` list.

  The compatibility trigger from `20260830120000` treated any change of
  `agent_id` alone as a legacy reassignment and stored `ARRAY[agent_id]`.
  That is the right bridge for a one-agent group. On a group that already
  names more than one scanner, the same write drops every scanner but the
  new scalar. Inserts that only set `agent_id` still fill `agent_ids`.
  """

  use Ecto.Migration

  @function "platform.sweep_groups_agent_ids_compat"

  def up do
    execute(compatibility_function_sql())
  end

  def down do
    execute(previous_function_sql())
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
            AND NEW.agent_ids IS NOT DISTINCT FROM OLD.agent_ids
            AND cardinality(COALESCE(OLD.agent_ids, ARRAY[]::text[])) <= 1 THEN
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

  def previous_function_sql do
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
end
