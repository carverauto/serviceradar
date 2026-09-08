defmodule ServiceRadar.Repo.Migrations.AddSnmpCredentialSecretRefs do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:snmp_profiles, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    alter table(:snmp_targets, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    alter table(:device_snmp_credentials, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    create index(:snmp_profiles, [:credential_secret_id],
             prefix: @prefix,
             name: :snmp_profiles_credential_secret_idx
           )

    create index(:snmp_targets, [:credential_secret_id],
             prefix: @prefix,
             name: :snmp_targets_credential_secret_idx
           )

    create index(:device_snmp_credentials, [:credential_secret_id],
             prefix: @prefix,
             name: :device_snmp_credentials_secret_idx
           )
  end
end
