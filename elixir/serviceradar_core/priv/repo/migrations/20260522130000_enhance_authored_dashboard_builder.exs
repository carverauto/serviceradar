defmodule ServiceRadar.Repo.Migrations.EnhanceAuthoredDashboardBuilder do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:authored_dashboards, prefix: @prefix) do
      add(:dashboard_ref, :integer)
    end

    execute("""
    UPDATE #{@prefix}.authored_dashboards AS dashboards
    SET dashboard_ref = numbered.dashboard_ref
    FROM (
      SELECT id, 1000000 + row_number() OVER (ORDER BY inserted_at, id) AS dashboard_ref
      FROM #{@prefix}.authored_dashboards
    ) AS numbered
    WHERE dashboards.id = numbered.id
      AND dashboards.dashboard_ref IS NULL
    """)

    alter table(:authored_dashboards, prefix: @prefix) do
      modify(:dashboard_ref, :integer, null: false)
    end

    create(
      unique_index(:authored_dashboards, [:dashboard_ref],
        name: :authored_dashboards_dashboard_ref_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:authored_dashboards, :authored_dashboards_dashboard_ref_range,
        check: "dashboard_ref BETWEEN 1000000 AND 9999999",
        prefix: @prefix
      )
    )

    alter table(:authored_dashboard_panels, prefix: @prefix) do
      add(:dataset_key, :text, null: false, default: "primary")
      add(:builder_state, :map, null: false, default: %{})
      add(:data_binding, :map, null: false, default: %{})
      add(:display_config, :map, null: false, default: %{})
    end

    create(
      index(:authored_dashboard_panels, [:dashboard_id, :dataset_key],
        name: :authored_dashboard_panels_dashboard_dataset_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:authored_dashboard_panels, [:dashboard_id, :dataset_key],
        name: :authored_dashboard_panels_dashboard_dataset_idx,
        prefix: @prefix
      )
    )

    alter table(:authored_dashboard_panels, prefix: @prefix) do
      remove(:display_config)
      remove(:data_binding)
      remove(:builder_state)
      remove(:dataset_key)
    end

    drop_if_exists(
      constraint(:authored_dashboards, :authored_dashboards_dashboard_ref_range, prefix: @prefix)
    )

    drop_if_exists(
      unique_index(:authored_dashboards, [:dashboard_ref],
        name: :authored_dashboards_dashboard_ref_idx,
        prefix: @prefix
      )
    )

    alter table(:authored_dashboards, prefix: @prefix) do
      remove(:dashboard_ref)
    end
  end
end
