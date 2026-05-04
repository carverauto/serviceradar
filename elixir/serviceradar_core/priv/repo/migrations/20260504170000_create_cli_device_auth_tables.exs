defmodule ServiceRadar.Repo.Migrations.CreateCliDeviceAuthTables do
  @moduledoc """
  Creates the tables backing the RFC 8628 CLI device-code flow.

  - `device_authorizations` — short-lived (15 min default) pending requests
    minted by `POST /api/v1/cli/auth/device`. The `/cli/auth/device`
    LiveView flips status to :approved or :denied; the polling endpoint
    consumes the row.
  - `cli_sessions` — long-lived metadata for issued JWTs (default 30 d
    TTL). Backs Settings → CLI sessions and the revoke flow.

  Both live in the deployment-isolated `platform` schema.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:device_authorizations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_code_hash, :text, null: false)
      add(:user_code, :text, null: false)
      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:status, :text, null: false, default: "pending")

      add(
        :user_id,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "device_authorizations_user_id_fkey",
          prefix: @prefix
        )
      )

      add(:expires_at, :utc_datetime_usec, null: false)
      add(:interval_seconds, :integer, null: false, default: 5)
      add(:last_polled_at, :utc_datetime_usec)
      add(:approved_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:device_authorizations, [:device_code_hash],
        name: :device_authorizations_unique_device_code_hash_idx,
        prefix: @prefix
      )
    )

    create(
      unique_index(:device_authorizations, [:user_code],
        name: :device_authorizations_unique_user_code_idx,
        prefix: @prefix
      )
    )

    create(
      index(:device_authorizations, [:status, :expires_at],
        name: :device_authorizations_status_expires_idx,
        prefix: @prefix
      )
    )

    create(
      index(:device_authorizations, [:user_id],
        name: :device_authorizations_user_idx,
        prefix: @prefix
      )
    )

    create table(:cli_sessions, primary_key: false, prefix: @prefix) do
      add(:jti, :text, null: false, primary_key: true)

      add(
        :device_authorization_id,
        references(:device_authorizations,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(
        :user_id,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :delete_all,
          name: "cli_sessions_user_id_fkey",
          prefix: @prefix
        ),
        null: false
      )

      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec)
      add(:last_used_ip, :text)
      add(:use_count, :integer, null: false, default: 0)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_by, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:cli_sessions, [:user_id, :status],
        name: :cli_sessions_user_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:cli_sessions, [:status, :expires_at],
        name: :cli_sessions_status_expires_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:cli_sessions, prefix: @prefix))
    drop_if_exists(table(:device_authorizations, prefix: @prefix))
  end
end
