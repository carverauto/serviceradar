defmodule ServiceRadar.Repo.Migrations.FenceAlertRuleAdmission do
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - this migration only creates
  # trigger functions and triggers; the UPDATE statements below live inside
  # those function bodies and run on future row writes, never as a
  # synchronous backfill on the first-boot path.
  def up do
    # All writers, including raw SQL and AshEvents replay, share the short
    # admission boundary. This never acquires an evaluator's ownership fence.
    execute("""
    CREATE FUNCTION platform.fence_alert_rule_admission() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('alert-evaluation:admission:v1', 0));
      IF TG_OP = 'DELETE' OR
         (TG_OP = 'UPDATE' AND OLD.enabled IS TRUE AND NEW.enabled IS DISTINCT FROM TRUE) THEN
        UPDATE platform.alert_evaluation_lanes
        SET cancelled_through = greatest(cancelled_through, next_position),
            updated_at = timezone('utc', now())
        WHERE rule_id = OLD.id;
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER fence_alert_rule_admission
    BEFORE INSERT OR UPDATE OR DELETE ON platform.stateful_alert_rules
    FOR EACH ROW EXECUTE FUNCTION platform.fence_alert_rule_admission()
    """)

    execute("""
    CREATE FUNCTION platform.cancel_alert_inputs_before_rule_replay() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('alert-evaluation:admission:v1', 0));
      UPDATE platform.alert_evaluation_lanes
      SET cancelled_through = greatest(cancelled_through, next_position),
          updated_at = timezone('utc', now());
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER cancel_alert_inputs_before_rule_replay
    BEFORE TRUNCATE ON platform.stateful_alert_rules
    FOR EACH STATEMENT EXECUTE FUNCTION platform.cancel_alert_inputs_before_rule_replay()
    """)
  end

  def down do
    execute("DROP TRIGGER cancel_alert_inputs_before_rule_replay ON platform.stateful_alert_rules")
    execute("DROP FUNCTION platform.cancel_alert_inputs_before_rule_replay()")
    execute("DROP TRIGGER fence_alert_rule_admission ON platform.stateful_alert_rules")
    execute("DROP FUNCTION platform.fence_alert_rule_admission()")
  end
end
