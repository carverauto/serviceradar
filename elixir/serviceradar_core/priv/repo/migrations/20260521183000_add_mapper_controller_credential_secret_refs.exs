defmodule ServiceRadar.Repo.Migrations.AddMapperControllerCredentialSecretRefs do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:mapper_unifi_controllers, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    alter table(:mapper_mikrotik_controllers, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    create index(:mapper_unifi_controllers, [:credential_secret_id],
             prefix: @prefix,
             name: :mapper_unifi_controllers_credential_secret_idx
           )

    create index(:mapper_mikrotik_controllers, [:credential_secret_id],
             prefix: @prefix,
             name: :mapper_mikrotik_controllers_credential_secret_idx
           )
  end
end
