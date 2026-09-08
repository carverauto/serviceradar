defmodule ServiceRadar.Repo.Migrations.AddCredentialRuleSourceScope do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:network_credential_rules, prefix: @prefix) do
      # These UUIDs identify the configured integration/controller for future
      # observations. They do not assign provenance to legacy inventory rows.
      add :integration_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()")

      add :controller_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()")
    end

    create unique_index(:network_credential_rules, [:integration_id],
             prefix: @prefix,
             name: :network_credential_rules_integration_id_uidx
           )

    create unique_index(:network_credential_rules, [:controller_id],
             prefix: @prefix,
             name: :network_credential_rules_controller_id_uidx
           )

    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.guard_network_credential_rule_source_scope()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.integration_id IS DISTINCT FROM NEW.integration_id
         OR OLD.controller_id IS DISTINCT FROM NEW.controller_id THEN
        RAISE EXCEPTION 'network credential rule source scope is immutable'
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER network_credential_rule_source_scope_immutable_guard
    BEFORE UPDATE OF integration_id, controller_id
    ON #{@prefix}.network_credential_rules
    FOR EACH ROW
    EXECUTE FUNCTION #{@prefix}.guard_network_credential_rule_source_scope()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS network_credential_rule_source_scope_immutable_guard
    ON #{@prefix}.network_credential_rules
    """)

    execute("DROP FUNCTION IF EXISTS #{@prefix}.guard_network_credential_rule_source_scope()")

    drop_if_exists(
      unique_index(:network_credential_rules, [:controller_id],
        prefix: @prefix,
        name: :network_credential_rules_controller_id_uidx
      )
    )

    drop_if_exists(
      unique_index(:network_credential_rules, [:integration_id],
        prefix: @prefix,
        name: :network_credential_rules_integration_id_uidx
      )
    )

    alter table(:network_credential_rules, prefix: @prefix) do
      remove :controller_id
      remove :integration_id
    end
  end
end
