defmodule ServiceRadar.Repo.Migrations.AddCliAuthorizationCodes do
  @moduledoc """
  One-time authorization codes for `serviceradar-cli auth login --web`.

  The CLI already runs the PKCE client. This table stores the code hash,
  the S256 challenge, and the loopback redirect the browser must return to.
  The plaintext code is never stored.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:cli_authorization_codes, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :user_id,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:client_id, :text, null: false)
      add(:code_hash, :text, null: false)
      add(:redirect_uri, :text, null: false)
      add(:code_challenge, :text, null: false)
      add(:scope, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)

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
      unique_index(:cli_authorization_codes, [:code_hash],
        name: :cli_authorization_codes_unique_code_hash_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:cli_authorization_codes, [:code_hash],
        name: :cli_authorization_codes_unique_code_hash_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(table(:cli_authorization_codes, prefix: @prefix))
  end
end
