defmodule ServiceRadar.Repo.Migrations.AddArmisNorthboundPopulationLedger do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute(
      """
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
      """,
      """
      DROP FUNCTION IF EXISTS platform.lock_armis_identifier_ownership();
      """
    )

    execute(
      """
      CREATE TRIGGER device_identifiers_armis_ownership_lock
      BEFORE INSERT OR UPDATE OR DELETE ON platform.device_identifiers
      FOR EACH ROW
      EXECUTE FUNCTION platform.lock_armis_identifier_ownership();
      """,
      """
      DROP TRIGGER IF EXISTS device_identifiers_armis_ownership_lock
        ON platform.device_identifiers;
      """
    )

    alter table(:integration_update_runs, prefix: "platform") do
      add :collection_id, :text
      add :collection_content_hash, :text
      add :collection_observed_at, :utc_datetime_usec
      add :raw_rows, :bigint, null: false, default: 0
      add :excluded_rows, :bigint, null: false, default: 0
      add :invalid_rows, :bigint, null: false, default: 0
      add :valid_occurrences, :bigint, null: false, default: 0
      add :distinct_source_ids, :bigint, null: false, default: 0
      add :duplicate_occurrences, :bigint, null: false, default: 0
      add :conflicting_duplicate_ids, :bigint, null: false, default: 0
      add :eligible_count, :bigint, null: false, default: 0
      add :withheld_count, :bigint, null: false, default: 0
      add :accepted_count, :bigint, null: false, default: 0
      add :failed_count, :bigint, null: false, default: 0
      add :unattempted_count, :bigint, null: false, default: 0
      add :reconciliation_status, :text, null: false, default: "unavailable"
    end

    create index(:integration_update_runs, [:integration_source_id, :collection_id],
             prefix: "platform",
             name: "integration_update_runs_source_collection_idx",
             where: "collection_id IS NOT NULL"
           )

    create unique_index(:integration_update_runs, [:id, :collection_id],
             prefix: "platform",
             name: "integration_update_runs_id_collection_uidx"
           )

    create constraint(:integration_update_runs, :integration_update_runs_inbound_equations,
             check:
               "raw_rows = excluded_rows + invalid_rows + valid_occurrences AND valid_occurrences = distinct_source_ids + duplicate_occurrences",
             prefix: "platform"
           )

    create constraint(:integration_update_runs, :integration_update_runs_disposition_equation,
             check:
               "collection_id IS NULL OR distinct_source_ids = eligible_count + withheld_count",
             prefix: "platform"
           )

    create constraint(:integration_update_runs, :integration_update_runs_outcome_equation,
             check:
               "collection_id IS NULL OR status = 'running' OR eligible_count = accepted_count + failed_count + unattempted_count",
             prefix: "platform"
           )

    create constraint(:integration_update_runs, :integration_update_runs_reconciliation_status,
             check:
               "reconciliation_status IN ('unavailable', 'pending', 'reconciled', 'degraded', 'failed')",
             prefix: "platform"
           )

    create table(:integration_update_run_targets, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :integration_update_run_id,
          references(:integration_update_runs,
            column: :id,
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :collection_id, :text, null: false
      add :source_object_id, :text, null: false
      add :canonical_device_uid, :text
      add :eligibility, :text, null: false
      add :outcome, :text, null: false
      add :reason, :text
      add :is_available, :boolean
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      ALTER TABLE platform.integration_update_run_targets
      ADD CONSTRAINT integration_update_run_targets_run_collection_fkey
      FOREIGN KEY (integration_update_run_id, collection_id)
      REFERENCES platform.integration_update_runs (id, collection_id)
      ON DELETE CASCADE;
      """,
      """
      ALTER TABLE platform.integration_update_run_targets
      DROP CONSTRAINT IF EXISTS integration_update_run_targets_run_collection_fkey;
      """
    )

    create unique_index(
             :integration_update_run_targets,
             [:integration_update_run_id, :source_object_id],
             prefix: "platform",
             name: "integration_update_run_targets_run_source_uidx"
           )

    create index(:integration_update_run_targets, [:integration_update_run_id, :outcome],
             prefix: "platform",
             name: "integration_update_run_targets_run_outcome_idx"
           )

    create index(:integration_update_run_targets, [:integration_update_run_id, :reason],
             prefix: "platform",
             name: "integration_update_run_targets_run_reason_idx",
             where: "reason IS NOT NULL"
           )

    create index(:integration_update_run_targets, [:updated_at, :id],
             prefix: "platform",
             name: "integration_update_run_targets_accepted_retention_idx",
             where: "outcome = 'accepted'"
           )

    create constraint(
             :integration_update_run_targets,
             :integration_update_run_targets_eligibility,
             check: "eligibility IN ('eligible', 'withheld')",
             prefix: "platform"
           )

    create constraint(:integration_update_run_targets, :integration_update_run_targets_outcome,
             check: "outcome IN ('pending', 'accepted', 'failed', 'unattempted', 'withheld')",
             prefix: "platform"
           )

    create constraint(
             :integration_update_run_targets,
             :integration_update_run_targets_disposition_outcome,
             check:
               "(eligibility = 'withheld' AND outcome = 'withheld') OR (eligibility = 'eligible' AND outcome IN ('pending', 'accepted', 'failed', 'unattempted'))",
             prefix: "platform"
           )

    execute(
      """
      CREATE OR REPLACE FUNCTION platform.enforce_armis_northbound_ledger_immutability()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_TABLE_NAME = 'integration_update_runs' THEN
          IF OLD.collection_id IS NOT NULL AND ROW(
            OLD.collection_id,
            OLD.collection_content_hash,
            OLD.collection_observed_at,
            OLD.raw_rows,
            OLD.excluded_rows,
            OLD.invalid_rows,
            OLD.valid_occurrences,
            OLD.distinct_source_ids,
            OLD.duplicate_occurrences,
            OLD.conflicting_duplicate_ids,
            OLD.eligible_count,
            OLD.withheld_count
          ) IS DISTINCT FROM ROW(
            NEW.collection_id,
            NEW.collection_content_hash,
            NEW.collection_observed_at,
            NEW.raw_rows,
            NEW.excluded_rows,
            NEW.invalid_rows,
            NEW.valid_occurrences,
            NEW.distinct_source_ids,
            NEW.duplicate_occurrences,
            NEW.conflicting_duplicate_ids,
            NEW.eligible_count,
            NEW.withheld_count
          ) THEN
            RAISE EXCEPTION 'northbound run collection binding is immutable'
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END IF;

        IF ROW(
          OLD.integration_update_run_id,
          OLD.collection_id,
          OLD.source_object_id,
          OLD.canonical_device_uid,
          OLD.eligibility,
          OLD.reason,
          OLD.is_available,
          OLD.metadata
        ) IS DISTINCT FROM ROW(
          NEW.integration_update_run_id,
          NEW.collection_id,
          NEW.source_object_id,
          NEW.canonical_device_uid,
          NEW.eligibility,
          NEW.reason,
          NEW.is_available,
          NEW.metadata
        ) THEN
          RAISE EXCEPTION 'northbound target disposition is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.outcome <> 'pending' AND OLD.outcome IS DISTINCT FROM NEW.outcome THEN
          RAISE EXCEPTION 'northbound target terminal outcome is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      """
      DROP FUNCTION IF EXISTS platform.enforce_armis_northbound_ledger_immutability();
      """
    )

    execute(
      """
      CREATE TRIGGER integration_update_runs_collection_immutable
      BEFORE UPDATE ON platform.integration_update_runs
      FOR EACH ROW
      EXECUTE FUNCTION platform.enforce_armis_northbound_ledger_immutability();
      """,
      """
      DROP TRIGGER IF EXISTS integration_update_runs_collection_immutable
        ON platform.integration_update_runs;
      """
    )

    execute(
      """
      CREATE TRIGGER integration_update_run_targets_disposition_immutable
      BEFORE UPDATE ON platform.integration_update_run_targets
      FOR EACH ROW
      EXECUTE FUNCTION platform.enforce_armis_northbound_ledger_immutability();
      """,
      """
      DROP TRIGGER IF EXISTS integration_update_run_targets_disposition_immutable
        ON platform.integration_update_run_targets;
      """
    )
  end
end
