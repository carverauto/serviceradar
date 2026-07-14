defmodule ServiceRadar.Repo.Migrations.PinAwxCallbackCredentialContract do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @constraint "ansible_awx_template_bindings_callback_slot"

  def up do
    # serviceradar:allow-startup-maintenance - revoking callback bindings whose
    # credential authority was never pinned is required before the stronger
    # constraint can admit application traffic. The update is limited to the
    # finite current callback-binding set, with local deadlines that fail the
    # transactional migration rather than permit a partial authority change.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:ansible_awx_template_bindings, prefix: @prefix) do
      add(:callback_credential_organization_id, :bigint)
      add(:callback_credential_injector_digest, :text)
    end

    # Legacy callback bindings did not review organization or injector
    # identity. They can never be made safe by guessing those values, so make
    # every such version non-current before the stronger contract is installed.
    execute("""
    UPDATE platform.ansible_awx_template_bindings
       SET current = false,
           approval_state = 'revoked',
           superseded_at = COALESCE(superseded_at, (now() AT TIME ZONE 'utc')),
           updated_at = (now() AT TIME ZONE 'utc')
     WHERE cardinality(callback_actions) > 0
       AND current = true
    """)

    drop constraint(:ansible_awx_template_bindings, @constraint, prefix: @prefix)

    # NOT VALID permits retained historical versions that predate the full
    # contract. PostgreSQL still enforces this check on every new or updated
    # row, while current-authority rejects those revoked legacy versions.
    execute("""
    ALTER TABLE platform.ansible_awx_template_bindings
      ADD CONSTRAINT #{@constraint}
      CHECK (
        (cardinality(callback_actions) = 0
          AND callback_credential_type_id IS NULL
          AND callback_credential_organization_id IS NULL
          AND callback_credential_injector_digest IS NULL
          AND callback_credential_slot IS NULL)
        OR
        (cardinality(callback_actions) > 0
          AND callback_credential_type_id > 0
          AND callback_credential_organization_id > 0
          AND callback_credential_injector_digest ~ '^[0-9a-f]{64}$'
          AND callback_credential_slot IS NOT NULL)
      ) NOT VALID
    """)
  end

  def down do
    drop constraint(:ansible_awx_template_bindings, @constraint, prefix: @prefix)

    alter table(:ansible_awx_template_bindings, prefix: @prefix) do
      remove(:callback_credential_organization_id)
      remove(:callback_credential_injector_digest)
    end

    create constraint(:ansible_awx_template_bindings, @constraint,
             prefix: @prefix,
             check:
               "(cardinality(callback_actions) = 0 AND callback_credential_type_id IS NULL AND " <>
                 "callback_credential_slot IS NULL) OR " <>
                 "(cardinality(callback_actions) > 0 AND callback_credential_type_id > 0 AND " <>
                 "callback_credential_slot IS NOT NULL)"
           )
  end
end
