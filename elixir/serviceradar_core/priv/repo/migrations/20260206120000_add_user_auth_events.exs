defmodule ServiceRadar.Repo.Migrations.AddUserAuthEvents do
  @moduledoc """
  Add immutable user auth/audit events for account inspection and security reviews.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:user_auth_events, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :user_id,
          references(:ng_users,
            column: :id,
            name: "user_auth_events_user_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :actor_user_id,
          references(:ng_users,
            column: :id,
            name: "user_auth_events_actor_user_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :event_type, :text, null: false
      add :auth_method, :text
      add :ip, :text
      add :user_agent, :text
      add :metadata, :map

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:user_auth_events, [:user_id, :inserted_at], prefix: "platform")
    create index(:user_auth_events, [:actor_user_id, :inserted_at], prefix: "platform")
    create index(:user_auth_events, [:event_type], prefix: "platform")
  end

  def down do
    drop_if_exists index(:user_auth_events, [:event_type], prefix: "platform")
    drop_if_exists index(:user_auth_events, [:actor_user_id, :inserted_at], prefix: "platform")
    drop_if_exists index(:user_auth_events, [:user_id, :inserted_at], prefix: "platform")

    drop constraint(:user_auth_events, "user_auth_events_actor_user_id_fkey", prefix: "platform")
    drop constraint(:user_auth_events, "user_auth_events_user_id_fkey", prefix: "platform")

    drop table(:user_auth_events, prefix: "platform")
  end
end

