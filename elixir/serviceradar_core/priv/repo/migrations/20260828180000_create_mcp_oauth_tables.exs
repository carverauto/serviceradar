defmodule ServiceRadar.Repo.Migrations.CreateMcpOauthTables do
  @moduledoc """
  Authorization-code + refresh tables for MCP OAuth through existing SSO.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:mcp_oauth_grants, primary_key: false, prefix: @prefix) do
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
      add(:scope, :text, null: false)
      add(:auth_method, :text, null: false)
      add(:idp_iss, :text)
      add(:idp_sid, :text)
      add(:encrypted_idp_refresh_token, :binary)
      add(:revoked_at, :utc_datetime_usec)

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
      unique_index(:mcp_oauth_grants, [:user_id, :client_id],
        name: :mcp_oauth_grants_active_user_client_idx,
        where: "revoked_at IS NULL",
        prefix: @prefix
      )
    )

    create(
      index(:mcp_oauth_grants, [:idp_iss, :idp_sid],
        name: :mcp_oauth_grants_idp_sid_idx,
        prefix: @prefix
      )
    )

    create table(:mcp_oauth_codes, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :grant_id,
        references(:mcp_oauth_grants, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

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
      unique_index(:mcp_oauth_codes, [:code_hash],
        name: :mcp_oauth_codes_unique_code_hash_idx,
        prefix: @prefix
      )
    )

    create table(:mcp_oauth_refresh_tokens, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:family_id, :uuid, null: false)

      add(
        :grant_id,
        references(:mcp_oauth_grants, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

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
      add(:token_hash, :text, null: false)
      add(:scope, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:replaced_by_id, :uuid)

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
      unique_index(:mcp_oauth_refresh_tokens, [:token_hash],
        name: :mcp_oauth_refresh_tokens_unique_hash_idx,
        prefix: @prefix
      )
    )

    create(
      index(:mcp_oauth_refresh_tokens, [:family_id],
        name: :mcp_oauth_refresh_tokens_family_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:mcp_oauth_refresh_tokens, prefix: @prefix))
    drop_if_exists(table(:mcp_oauth_codes, prefix: @prefix))
    drop_if_exists(table(:mcp_oauth_grants, prefix: @prefix))
  end
end
