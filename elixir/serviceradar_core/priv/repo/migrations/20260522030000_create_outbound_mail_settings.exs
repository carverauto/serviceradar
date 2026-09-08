defmodule ServiceRadar.Repo.Migrations.CreateOutboundMailSettings do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:outbound_mail_settings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:enabled, :boolean, null: false, default: false)
      add(:adapter, :text, null: false, default: "local")
      add(:from_name, :text, null: false, default: "ServiceRadar")
      add(:from_email, :text, null: false, default: "noreply@serviceradar.cloud")
      add(:relay, :text)
      add(:port, :integer)
      add(:hostname, :text)
      add(:username, :text)
      add(:encrypted_password, :binary)
      add(:encrypted_api_key, :binary)

      add(
        :password_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: "platform"
        )
      )

      add(
        :api_key_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: "platform"
        )
      )

      add(:auth, :text, null: false, default: "if_available")
      add(:tls, :text, null: false, default: "if_available")
      add(:ssl, :boolean, null: false, default: false)
      add(:retries, :integer, null: false, default: 1)
      add(:provider_options, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    execute("CREATE UNIQUE INDEX outbound_mail_settings_singleton ON platform.outbound_mail_settings ((1))")

    create index(:outbound_mail_settings, [:password_secret_id],
             prefix: "platform",
             name: :outbound_mail_settings_password_secret_idx
           )

    create index(:outbound_mail_settings, [:api_key_secret_id],
             prefix: "platform",
             name: :outbound_mail_settings_api_key_secret_idx
           )

    execute("""
    INSERT INTO platform.outbound_mail_settings (id, inserted_at, updated_at)
    VALUES (gen_random_uuid(), now(), now())
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop(table(:outbound_mail_settings, prefix: "platform"))
  end
end
