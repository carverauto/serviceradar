defmodule ServiceRadar.Repo.Migrations.AddIntegrationSourceCredentialSecretRefs do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:integration_sources, prefix: @prefix) do
      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )
    end

    create index(:integration_sources, [:credential_secret_id],
             prefix: @prefix,
             name: :integration_sources_credential_secret_idx
           )
  end
end
