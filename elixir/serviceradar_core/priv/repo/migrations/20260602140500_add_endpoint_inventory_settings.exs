defmodule ServiceRadar.Repo.Migrations.AddEndpointInventorySettings do
  use Ecto.Migration

  def change do
    create table(:endpoint_inventory_settings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:retention_days, :integer, null: false, default: 30)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:endpoint_inventory_settings, :endpoint_inventory_settings_retention_days_check,
        check: "retention_days BETWEEN 1 AND 365",
        prefix: "platform"
      )
    )
  end
end
