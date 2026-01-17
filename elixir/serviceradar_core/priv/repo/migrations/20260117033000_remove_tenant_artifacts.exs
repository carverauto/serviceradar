defmodule ServiceRadar.Repo.Migrations.RemoveTenantArtifacts do
  @moduledoc """
  Remove tenant-scoped artifacts and platform bootstrap tables from tenant instances.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:tenant_memberships, prefix: "public")
    drop_if_exists table(:tenants, prefix: "public")

    drop_if_exists table(:nats_platform_tokens, prefix: "public")
    drop_if_exists table(:nats_operators, prefix: "public")
    drop_if_exists table(:nats_service_accounts, prefix: "public")

    drop_if_exists index(:sysmon_profiles, [:tenant_id, :name],
                     name: "sysmon_profiles_unique_name_per_tenant_index"
                   )

    execute "ALTER TABLE sysmon_profiles DROP COLUMN IF EXISTS tenant_id"

    create unique_index(:sysmon_profiles, [:name], name: "sysmon_profiles_unique_name_index")
  end

  def down do
    drop_if_exists unique_index(:sysmon_profiles, [:name],
                     name: "sysmon_profiles_unique_name_index"
                   )

    alter table(:sysmon_profiles) do
      add :tenant_id, :uuid, null: false
    end

    create unique_index(:sysmon_profiles, [:tenant_id, :name],
             name: "sysmon_profiles_unique_name_per_tenant_index"
           )

    create table(:tenants, primary_key: false, prefix: "public") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :slug, :citext, null: false
      add :status, :text, null: false, default: "active"
      add :is_platform_tenant, :boolean, null: false, default: false
      add :settings, :map, default: %{}
      add :plan, :text, default: "free"
      add :max_devices, :bigint, default: 100
      add :max_users, :bigint, default: 5
      add :owner_id, :uuid
      add :nats_account_public_key, :text
      add :nats_account_jwt, :text
      add :nats_account_status, :text
      add :nats_account_error, :text
      add :nats_account_provisioned_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_contact_email, :binary
      add :encrypted_contact_name, :binary
      add :encrypted_nats_account_seed_ciphertext, :binary
    end

    create index(:tenants, [:is_platform_tenant],
             name: "tenants_unique_platform_tenant_index",
             unique: true,
             where: "is_platform_tenant = true",
             prefix: "public"
           )

    create unique_index(:tenants, [:slug], name: "tenants_unique_slug_index", prefix: "public")

    create table(:tenant_memberships, primary_key: false, prefix: "public") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :role, :text, null: false, default: "member"
      add :joined_at, :utc_datetime, null: false, default: fragment("(now() AT TIME ZONE 'utc')")

      add :tenant_id,
          references(:tenants,
            column: :id,
            name: "tenant_memberships_tenant_id_fkey",
            type: :uuid,
            prefix: "public"
          ), null: false

      add :user_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:tenant_memberships, [:tenant_id, :user_id],
             name: "tenant_memberships_unique_membership_index",
             prefix: "public"
           )

    create table(:nats_platform_tokens, primary_key: false, prefix: "public") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :token_hash, :text, null: false
      add :purpose, :text, null: false, default: "nats_bootstrap"
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      add :used_by_ip, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:nats_platform_tokens, [:token_hash],
             name: "nats_platform_tokens_unique_hash_index",
             prefix: "public"
           )

    create table(:nats_operators, primary_key: false, prefix: "public") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false, default: "serviceradar"
      add :public_key, :text
      add :operator_jwt, :text
      add :system_account_public_key, :text
      add :status, :text, null: false, default: "pending"
      add :error_message, :text
      add :bootstrapped_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_system_account_seed_ciphertext, :binary
    end

    create unique_index(:nats_operators, [:name],
             name: "nats_operators_unique_name_index",
             prefix: "public"
           )

    create table(:nats_service_accounts, primary_key: false, prefix: "public") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :account_public_key, :text
      add :account_jwt, :text
      add :user_public_key, :text
      add :status, :text, null: false, default: "pending"
      add :error_message, :text
      add :provisioned_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_account_seed_ciphertext, :binary
      add :encrypted_user_creds_ciphertext, :binary
    end

    create unique_index(:nats_service_accounts, [:name],
             name: "nats_service_accounts_unique_name_index",
             prefix: "public"
           )
  end
end
