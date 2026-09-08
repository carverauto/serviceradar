defmodule ServiceRadar.Repo.Migrations.AddTokenRevocations do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:token_revocations, primary_key: false, prefix: "platform") do
      add :jti, :text, primary_key: true, null: false

      add :user_id,
          references(:ng_users,
            column: :id,
            type: :uuid,
            on_delete: :nilify_all,
            name: "token_revocations_user_id_fkey",
            prefix: "platform"
          )

      add :reason, :text, null: false
      add :revoked_at, :utc_datetime_usec, null: false
      add :revoked_before, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:token_revocations, [:user_id], prefix: "platform")
    create index(:token_revocations, [:expires_at], prefix: "platform")
    create index(:token_revocations, [:user_id, :expires_at], prefix: "platform")
  end
end
