defmodule ServiceRadar.Repo.Migrations.MoveCoreOtxCredentialToInventory do
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded move of a small
    # singleton control-plane table into the canonical credential inventory.
    # The data copy moves one encrypted scalar per settings row (ciphertext
    # only, never decrypted) and clears the legacy copy; the WHERE clause
    # makes it idempotent (only rows that still hold a legacy key and lack a
    # reference). Deferring it would leave the core worker without its
    # credential reference on first boot after upgrade.
    alter table(:netflow_settings, prefix: "platform") do
      add :otx_credential_secret_id,
          references(:network_credential_secrets, type: :uuid, prefix: "platform", on_delete: :restrict)
    end
    flush()
    execute(fn -> migrate_legacy_tokens(repo()) end)
  end

  # Both scalar fields use ServiceRadar.Vault and AshCloak's identical string
  # serialization. Copy ciphertext in CNPG; no plaintext or key is read here.
  def migrate_legacy_tokens(repo) do
    repo.query!("""
    WITH legacy AS (
      SELECT id, gen_random_uuid() AS secret_id, encrypted_otx_api_key
      FROM platform.netflow_settings
      WHERE otx_credential_secret_id IS NULL AND encrypted_otx_api_key IS NOT NULL
      FOR UPDATE
    ), inserted AS (
      INSERT INTO platform.network_credential_secrets
        (id, name, provider, credential_kind, encrypted_secret_payload, metadata)
      SELECT secret_id, 'Core OTX migrated ' || id::text, 'alienvault-otx-core', 'api_token',
             encrypted_otx_api_key,
             '{"auth_method":"api_token","plugin_id":"alienvault-otx-core","plugin_version":"native"}'::jsonb
      FROM legacy
      RETURNING id
    )
    UPDATE platform.netflow_settings settings
    SET otx_credential_secret_id = legacy.secret_id, encrypted_otx_api_key = NULL
    FROM legacy JOIN inserted ON inserted.id = legacy.secret_id
    WHERE settings.id = legacy.id
    """)
  end

  def down do
    raise "Core OTX credentials now belong to the canonical inventory; downgrade requires explicit credential recovery"
  end
end
