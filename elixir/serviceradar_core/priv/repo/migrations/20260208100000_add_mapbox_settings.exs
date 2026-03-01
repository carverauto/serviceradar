defmodule ServiceRadar.Repo.Migrations.AddMapboxSettings do
  @moduledoc """
  Adds deployment-level Mapbox settings (singleton).

  We store:
  - optional enable flag
  - Mapbox public access token (encrypted at rest for admin management)
  - light/dark style URLs
  """

  use Ecto.Migration

  def up do
    create table(:mapbox_settings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:enabled, :boolean, null: false, default: false)
      add(:encrypted_access_token, :binary)

      add(:style_light, :text, null: false, default: "mapbox://styles/mapbox/light-v11")
      add(:style_dark, :text, null: false, default: "mapbox://styles/mapbox/dark-v11")

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    execute("CREATE UNIQUE INDEX mapbox_settings_singleton ON platform.mapbox_settings ((1))")

    execute("""
    INSERT INTO platform.mapbox_settings (id)
    VALUES (gen_random_uuid())
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop(table(:mapbox_settings, prefix: "platform"))
  end
end
