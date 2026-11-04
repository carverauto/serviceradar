defmodule ServiceRadar.Repo.Migrations.CreateEdgeContractRegistryEpochs do
  @moduledoc """
  One row per edge-record contract registry epoch: the core-derived, issuer-signed registry a
  release's catalog produces (`ServiceRadar.Edge.ContractRegistry`).

  The content columns (`epoch`, `snapshot_sha256`, `document`, `signature`, `signing_key_id`,
  `created_at`) are written once at insert and never change; a trigger refuses any update to
  them. Only `state`, its timestamps and `last_matched_at` move, and `state` only moves forward:
  `candidate` to `active` or `retired`, `active` to `draining`, `draining` to `retired`.

  Partial unique indexes allow at most one `active` and one `candidate` row, and keep
  `snapshot_sha256` unique among rows that were not retired unactivated. Epoch numbers start at
  1_000_000, above every installation-static registry label, so a record stamped below the floor
  provably predates the derived registry.
  """
  use Ecto.Migration

  @table "edge_contract_registry_epochs"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      epoch            BIGINT       PRIMARY KEY,
      snapshot_sha256  BYTEA        NOT NULL,
      document         JSONB        NOT NULL,
      signature        BYTEA        NOT NULL,
      signing_key_id   BYTEA        NOT NULL,
      state            TEXT         NOT NULL,
      created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
      activated_at     TIMESTAMPTZ,
      draining_since   TIMESTAMPTZ,
      drain_until      TIMESTAMPTZ,
      retired_at       TIMESTAMPTZ,
      last_matched_at  TIMESTAMPTZ  NOT NULL,
      CONSTRAINT edge_contract_registry_epochs_floor_chk CHECK (epoch >= 1000000),
      CONSTRAINT edge_contract_registry_epochs_snapshot_chk
        CHECK (octet_length(snapshot_sha256) = 32),
      CONSTRAINT edge_contract_registry_epochs_signature_chk CHECK (octet_length(signature) = 64),
      CONSTRAINT edge_contract_registry_epochs_key_id_chk CHECK (octet_length(signing_key_id) = 16),
      CONSTRAINT edge_contract_registry_epochs_document_chk
        CHECK (jsonb_typeof(document) = 'object'),
      CONSTRAINT edge_contract_registry_epochs_state_chk
        CHECK (state IN ('candidate', 'active', 'draining', 'retired')),
      CONSTRAINT edge_contract_registry_epochs_candidate_chk
        CHECK (state <> 'candidate' OR activated_at IS NULL),
      CONSTRAINT edge_contract_registry_epochs_active_chk
        CHECK (state <> 'active' OR activated_at IS NOT NULL),
      CONSTRAINT edge_contract_registry_epochs_draining_chk
        CHECK (state <> 'draining' OR
               (activated_at IS NOT NULL AND draining_since IS NOT NULL AND drain_until IS NOT NULL)),
      CONSTRAINT edge_contract_registry_epochs_retired_chk
        CHECK ((state = 'retired') = (retired_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS edge_contract_registry_epochs_one_active_uidx
      ON #{schema}.#{@table} (state) WHERE state = 'active'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS edge_contract_registry_epochs_one_candidate_uidx
      ON #{schema}.#{@table} (state) WHERE state = 'candidate'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS edge_contract_registry_epochs_snapshot_uidx
      ON #{schema}.#{@table} (snapshot_sha256)
      WHERE NOT (state = 'retired' AND activated_at IS NULL)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{schema}.edge_contract_registry_epochs_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.epoch IS DISTINCT FROM OLD.epoch
         OR NEW.snapshot_sha256 IS DISTINCT FROM OLD.snapshot_sha256
         OR NEW.document IS DISTINCT FROM OLD.document
         OR NEW.signature IS DISTINCT FROM OLD.signature
         OR NEW.signing_key_id IS DISTINCT FROM OLD.signing_key_id
         OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'edge contract registry epoch % content is immutable', OLD.epoch
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
           (OLD.state = 'candidate' AND NEW.state IN ('active', 'retired'))
           OR (OLD.state = 'active' AND NEW.state = 'draining')
           OR (OLD.state = 'draining' AND NEW.state = 'retired')
         ) THEN
        RAISE EXCEPTION 'edge contract registry epoch % cannot move from % to %',
          OLD.epoch, OLD.state, NEW.state
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE TRIGGER edge_contract_registry_epochs_guard_trg
      BEFORE UPDATE ON #{schema}.#{@table}
      FOR EACH ROW EXECUTE FUNCTION #{schema}.edge_contract_registry_epochs_guard()
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
    execute("DROP FUNCTION IF EXISTS #{schema}.edge_contract_registry_epochs_guard()")
  end
end
