defmodule ServiceRadar.Repo.Migrations.CreateWarehouseRetentionSettings do
  @moduledoc """
  One row per StarRocks warehouse dataset holding the operator's retention.

  Core seeds a missing row from the environment (Helm/Compose) and applies the
  stored value to the warehouse, recording the outcome on the row.
  """

  use Ecto.Migration

  def change do
    create table(:warehouse_retention_settings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true, null: false)
      add(:dataset, :text, null: false)
      add(:days, :integer, null: false)
      add(:seed_days, :integer)
      add(:updated_by, :text)
      add(:updated_at, :utc_datetime_usec)
      add(:last_applied_days, :integer)
      add(:last_applied_status, :text, null: false, default: "pending")
      add(:last_applied_error, :text)
      add(:last_applied_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:warehouse_retention_settings, [:dataset],
        name: :warehouse_retention_settings_unique_dataset_index,
        prefix: "platform"
      )
    )

    create(
      constraint(:warehouse_retention_settings, :warehouse_retention_settings_days_floor,
        check: "days BETWEEN 1 AND 3650",
        prefix: "platform"
      )
    )

    create(
      constraint(:warehouse_retention_settings, :warehouse_retention_settings_status,
        check: "last_applied_status IN ('applied', 'pending', 'failed')",
        prefix: "platform"
      )
    )
  end
end
