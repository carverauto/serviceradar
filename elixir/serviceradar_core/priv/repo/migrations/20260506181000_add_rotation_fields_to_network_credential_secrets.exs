defmodule ServiceRadar.Repo.Migrations.AddRotationFieldsToNetworkCredentialSecrets do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:network_credential_secrets, prefix: @prefix) do
      add :last_rotated_at, :utc_datetime_usec
      add :next_rotation_due_at, :utc_datetime_usec
    end

    create index(
             :network_credential_secrets,
             [:provider, :credential_kind, :next_rotation_due_at],
             prefix: @prefix,
             name: :network_credential_secrets_rotation_due_idx
           )
  end
end
