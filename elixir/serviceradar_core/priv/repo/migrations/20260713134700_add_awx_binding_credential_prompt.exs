defmodule ServiceRadar.Repo.Migrations.AddAwxBindingCredentialPrompt do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @constraint "ansible_awx_template_bindings_callback_prompt"

  def up do
    # serviceradar:allow-startup-maintenance - existing callback bindings lack
    # the reviewed AWX credential-prompt bit and must be revoked before the new
    # constraint becomes authoritative. This touches only the finite current
    # callback-binding set and uses local deadlines to avoid unbounded startup.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:ansible_awx_template_bindings, prefix: @prefix) do
      add(:ask_credential_on_launch, :boolean, null: false, default: false)
    end

    # Existing callback bindings were reviewed without this AWX prompt bit.
    # Its value cannot be inferred safely, so retire current versions and
    # require a fresh controller projection and review.
    execute("""
    UPDATE platform.ansible_awx_template_bindings
       SET current = false,
           approval_state = 'revoked',
           superseded_at = COALESCE(superseded_at, (now() AT TIME ZONE 'utc')),
           updated_at = (now() AT TIME ZONE 'utc')
     WHERE cardinality(callback_actions) > 0
       AND current = true
    """)

    # Historical revoked versions may retain false. PostgreSQL still enforces
    # a NOT VALID check for every new or updated callback-enabled binding.
    execute("""
    ALTER TABLE platform.ansible_awx_template_bindings
      ADD CONSTRAINT #{@constraint}
      CHECK (
        cardinality(callback_actions) = 0
        OR ask_credential_on_launch = true
      ) NOT VALID
    """)
  end

  def down do
    drop constraint(:ansible_awx_template_bindings, @constraint, prefix: @prefix)

    alter table(:ansible_awx_template_bindings, prefix: @prefix) do
      remove(:ask_credential_on_launch)
    end
  end
end
