defmodule ServiceRadar.Repo.Migrations.LockNetboxIdentifierOwnership do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
      CREATE OR REPLACE FUNCTION platform.lock_armis_identifier_ownership()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        old_device_id text;
        new_device_id text;
        first_device_id text;
        second_device_id text;
      BEGIN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          IF OLD.identifier_type IN ('armis_device_id', 'netbox_device_id') THEN
            old_device_id := OLD.device_id;
          END IF;
        END IF;

        IF TG_OP IN ('INSERT', 'UPDATE') THEN
          IF NEW.identifier_type IN ('armis_device_id', 'netbox_device_id') THEN
            new_device_id := NEW.device_id;
          END IF;
        END IF;

        IF old_device_id IS NULL AND new_device_id IS NULL THEN
          IF TG_OP = 'DELETE' THEN
            RETURN OLD;
          END IF;
          RETURN NEW;
        END IF;

        first_device_id := LEAST(old_device_id, new_device_id);
        second_device_id := GREATEST(old_device_id, new_device_id);

        IF first_device_id IS NULL THEN
          first_device_id := COALESCE(old_device_id, new_device_id);
        END IF;

        PERFORM pg_advisory_xact_lock(
          hashtextextended('serviceradar:armis-identifier-owner:' || first_device_id, 0)
        );

        IF second_device_id IS NOT NULL AND second_device_id <> first_device_id THEN
          PERFORM pg_advisory_xact_lock(
            hashtextextended('serviceradar:armis-identifier-owner:' || second_device_id, 0)
          );
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$;
      """)
  end

  def down do
    execute("""
      CREATE OR REPLACE FUNCTION platform.lock_armis_identifier_ownership()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        old_device_id text;
        new_device_id text;
        first_device_id text;
        second_device_id text;
      BEGIN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          IF OLD.identifier_type = 'armis_device_id' THEN
            old_device_id := OLD.device_id;
          END IF;
        END IF;

        IF TG_OP IN ('INSERT', 'UPDATE') THEN
          IF NEW.identifier_type = 'armis_device_id' THEN
            new_device_id := NEW.device_id;
          END IF;
        END IF;

        IF old_device_id IS NULL AND new_device_id IS NULL THEN
          IF TG_OP = 'DELETE' THEN
            RETURN OLD;
          END IF;
          RETURN NEW;
        END IF;

        first_device_id := LEAST(old_device_id, new_device_id);
        second_device_id := GREATEST(old_device_id, new_device_id);

        IF first_device_id IS NULL THEN
          first_device_id := COALESCE(old_device_id, new_device_id);
        END IF;

        PERFORM pg_advisory_xact_lock(
          hashtextextended('serviceradar:armis-identifier-owner:' || first_device_id, 0)
        );

        IF second_device_id IS NOT NULL AND second_device_id <> first_device_id THEN
          PERFORM pg_advisory_xact_lock(
            hashtextextended('serviceradar:armis-identifier-owner:' || second_device_id, 0)
          );
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$;
      """)
  end
end
