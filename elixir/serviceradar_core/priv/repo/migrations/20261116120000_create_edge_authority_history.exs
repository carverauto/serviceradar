defmodule ServiceRadar.Repo.Migrations.CreateEdgeAuthorityHistory do
  @moduledoc """
  Append-only history of every producer-authority interval
  (openspec add-edge-production-time-admission, design Decision 4).

  `sweep_producer_assignments` and `edge_output_grants` are current-state rows: their
  `authority_epoch`, `epoch_changed_at` and `revoked_at` are overwritten, and a sweep-group
  delete cascades their rows away. A record admitted LATE must be judged against the authority
  that was live WHEN IT WAS PRODUCED, so core needs the intervals those rows passed through.

  ## Why a trigger

  Every writer must be recorded, including raw SQL and bulk updates that never build an Ash
  changeset and the `ON DELETE CASCADE` from `sweep_groups` (AGENTS.md: find every writer,
  not the obvious one). A trigger sits below all of them.

  ## Rules

    * INSERT of an active row opens an interval at its epoch.
    * An UPDATE of epoch, state, agent, scope or shard closes the open interval, with
      `ended_reason` derived from the row's `epoch_reason`, and opens the next one only when the
      row is still `active`. A revoked row has no live epoch, so revocation only closes.
    * DELETE only closes the open interval (`deleted`) and never opens a successor, so a record
      produced after the delete falls outside every window.
    * Output-grant revocation carries its cause in `epoch_reason`
      (`identity_superseded` or `certificate_revoked`). A legacy `revoked` reason on a grant
      cannot tell the two apart, so it closes as `revoked_cause_unknown`, which is handled
      exactly like `certificate_revoked`: never backfilled.
    * History rows are immutable except for setting `active_until` and `ended_reason` once.
      Deleting rows is allowed: retention prunes ended intervals outside the late window
      (never `certificate_revoked` or `revoked_cause_unknown`; that rule lives in the pruner).

  ## Seed

  One interval per existing row, from evidence that exists and nothing more: an active row opens
  at its current epoch from `epoch_changed_at` (or `inserted_at`); a revoked row's last live epoch
  (`authority_epoch - 1`, because revocation bumped it) closes at `revoked_at`. A revoked output
  grant seeds as `revoked_cause_unknown`; a revoked sweep assignment as `revoked`. Earlier epochs
  have no evidence and are not invented; a record naming one is `history_unknown` (AUDIT).
  """

  use Ecto.Migration

  @table "edge_authority_history"

  def up do
    schema = prefix() || "platform"

    # CREATE TRIGGER and the explicit seed lock below take SHARE ROW EXCLUSIVE on
    # sweep_producer_assignments and edge_output_grants until commit, which blocks writes to
    # them. Never queue behind a long transaction: fail fast and let the migration be retried.
    # Once acquired, the lock is held only for the set-based seed (one INSERT ... SELECT over
    # both tables), which is proportional to their row count.
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id bigserial PRIMARY KEY,
      assignment_id uuid NOT NULL,
      assignment_kind text NOT NULL CHECK (assignment_kind IN ('sweep', 'output_grant')),
      agent_id text NOT NULL,
      network_scope_id uuid NOT NULL,
      run_shard bigint NOT NULL,
      authority_epoch bigint NOT NULL,
      active_from timestamptz NOT NULL,
      active_until timestamptz,
      ended_reason text CHECK (ended_reason IN (
        'epoch_changed', 'binding_changed', 'revoked', 'identity_superseded',
        'certificate_revoked', 'revoked_cause_unknown', 'compromised', 'deleted'
      )),
      CHECK ((active_until IS NULL) = (ended_reason IS NULL)),
      CHECK (active_until IS NULL OR active_until >= active_from)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS edge_authority_history_one_open_uidx
      ON #{schema}.#{@table} (assignment_id) WHERE active_until IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS edge_authority_history_epoch_idx
      ON #{schema}.#{@table} (assignment_id, authority_epoch)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS edge_authority_history_ended_idx
      ON #{schema}.#{@table} (active_until) WHERE active_until IS NOT NULL
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{schema}.edge_authority_history_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.assignment_id IS DISTINCT FROM OLD.assignment_id
         OR NEW.assignment_kind IS DISTINCT FROM OLD.assignment_kind
         OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
         OR NEW.network_scope_id IS DISTINCT FROM OLD.network_scope_id
         OR NEW.run_shard IS DISTINCT FROM OLD.run_shard
         OR NEW.authority_epoch IS DISTINCT FROM OLD.authority_epoch
         OR NEW.active_from IS DISTINCT FROM OLD.active_from
         OR (OLD.active_until IS NOT NULL AND (
               NEW.active_until IS DISTINCT FROM OLD.active_until
               OR NEW.ended_reason IS DISTINCT FROM OLD.ended_reason)) THEN
        RAISE EXCEPTION 'edge authority history interval % is immutable', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE TRIGGER edge_authority_history_guard_trg
      BEFORE UPDATE ON #{schema}.#{@table}
      FOR EACH ROW EXECUTE FUNCTION #{schema}.edge_authority_history_guard()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{schema}.edge_authority_history_record()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      kind text := CASE TG_TABLE_NAME WHEN 'edge_output_grants' THEN 'output_grant' ELSE 'sweep' END;
      at timestamptz;
      reason text;
      open_id bigint;
      open_from timestamptz;
      last_until timestamptz;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        SELECT id, active_from INTO open_id, open_from
          FROM #{schema}.#{@table}
         WHERE assignment_id = OLD.id AND active_until IS NULL
           FOR UPDATE;

        IF FOUND THEN
          at := now();
          IF at <= open_from THEN
            at := GREATEST(clock_timestamp(), open_from + interval '1 microsecond');
          END IF;

          UPDATE #{schema}.#{@table}
             SET active_until = at, ended_reason = 'deleted'
           WHERE id = open_id;
        END IF;

        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.authority_epoch IS NOT DISTINCT FROM OLD.authority_epoch
           AND NEW.state IS NOT DISTINCT FROM OLD.state
           AND NEW.agent_id IS NOT DISTINCT FROM OLD.agent_id
           AND NEW.network_scope_id IS NOT DISTINCT FROM OLD.network_scope_id
           AND NEW.run_shard IS NOT DISTINCT FROM OLD.run_shard THEN
          RETURN NEW;
        END IF;

        reason := CASE
          WHEN NEW.authority_epoch IS NOT DISTINCT FROM OLD.authority_epoch
               AND NEW.state IS NOT DISTINCT FROM OLD.state THEN 'binding_changed'
          WHEN NEW.epoch_reason::text IN ('identity_superseded', 'certificate_revoked', 'compromised')
            THEN NEW.epoch_reason::text
          WHEN NEW.epoch_reason::text = 'revoked' AND kind = 'output_grant' THEN 'revoked_cause_unknown'
          WHEN NEW.epoch_reason::text = 'revoked' THEN 'revoked'
          ELSE 'epoch_changed'
        END;
        at := CASE
          WHEN NEW.authority_epoch IS DISTINCT FROM OLD.authority_epoch
            THEN COALESCE(NEW.epoch_changed_at, now())
          ELSE now()
        END;

        SELECT id, active_from INTO open_id, open_from
          FROM #{schema}.#{@table}
         WHERE assignment_id = NEW.id AND active_until IS NULL
           FOR UPDATE;

        IF FOUND THEN
          IF at <= open_from THEN
            at := GREATEST(clock_timestamp(), open_from + interval '1 microsecond');
          END IF;

          UPDATE #{schema}.#{@table}
             SET active_until = at, ended_reason = reason
           WHERE id = open_id;
        END IF;
      ELSE
        at := COALESCE(NEW.epoch_changed_at, NEW.inserted_at, now());
      END IF;

      IF NEW.state::text = 'active' THEN
        -- A successor never starts before an earlier interval of the same assignment ended
        -- (reactivating a revoked row in the transaction that revoked it reads the same
        -- now()), so intervals stay half-open and no produced_at matches two epochs.
        SELECT max(active_until) INTO last_until
          FROM #{schema}.#{@table}
         WHERE assignment_id = NEW.id;

        IF last_until IS NOT NULL AND last_until > at THEN
          at := last_until;
        END IF;

        INSERT INTO #{schema}.#{@table}
          (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
           authority_epoch, active_from)
        VALUES
          (NEW.id, kind, NEW.agent_id, NEW.network_scope_id, NEW.run_shard,
           NEW.authority_epoch, at);
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    for table <- ["sweep_producer_assignments", "edge_output_grants"] do
      execute("""
      CREATE OR REPLACE TRIGGER #{table}_authority_history_trg
        AFTER INSERT OR UPDATE OR DELETE ON #{schema}.#{table}
        FOR EACH ROW EXECUTE FUNCTION #{schema}.edge_authority_history_record()
      """)
    end

    # Hold both source tables until commit so no write lands between the seed snapshot and the
    # moment the triggers become visible to other sessions (CREATE TRIGGER already takes this
    # lock; stating it keeps the guarantee if the statements are ever reordered).
    execute("""
    LOCK TABLE #{schema}.sweep_producer_assignments, #{schema}.edge_output_grants
      IN SHARE ROW EXCLUSIVE MODE
    """)

    execute("""
    INSERT INTO #{schema}.#{@table}
      (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
       authority_epoch, active_from, active_until, ended_reason)
    SELECT id, kind, agent_id, network_scope_id, run_shard,
           CASE WHEN state::text = 'active' THEN authority_epoch ELSE authority_epoch - 1 END,
           CASE WHEN state::text = 'active' THEN COALESCE(epoch_changed_at, inserted_at)
                ELSE LEAST(inserted_at, COALESCE(revoked_at, inserted_at)) END,
           CASE WHEN state::text = 'active' THEN NULL ELSE COALESCE(revoked_at, epoch_changed_at, now()) END,
           CASE WHEN state::text = 'active' THEN NULL
                WHEN kind = 'output_grant' THEN 'revoked_cause_unknown'
                ELSE 'revoked' END
      FROM (
        SELECT id, 'sweep' AS kind, agent_id, network_scope_id, run_shard, authority_epoch,
               state, epoch_changed_at, revoked_at, inserted_at
          FROM #{schema}.sweep_producer_assignments
        UNION ALL
        SELECT id, 'output_grant', agent_id, network_scope_id, run_shard, authority_epoch,
               state, epoch_changed_at, revoked_at, inserted_at
          FROM #{schema}.edge_output_grants
      ) AS current_rows
     WHERE state::text = 'active' OR authority_epoch > 1
    """)
  end

  def down do
    schema = prefix() || "platform"

    for table <- ["sweep_producer_assignments", "edge_output_grants"] do
      execute("DROP TRIGGER IF EXISTS #{table}_authority_history_trg ON #{schema}.#{table}")
    end

    execute("""
    UPDATE #{schema}.edge_output_grants
       SET epoch_reason = 'revoked'
     WHERE epoch_reason IN ('identity_superseded', 'certificate_revoked')
    """)

    execute("DROP FUNCTION IF EXISTS #{schema}.edge_authority_history_record()")
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
    execute("DROP FUNCTION IF EXISTS #{schema}.edge_authority_history_guard()")
  end
end
