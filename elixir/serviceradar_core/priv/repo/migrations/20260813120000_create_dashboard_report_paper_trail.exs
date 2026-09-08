defmodule ServiceRadar.Repo.Migrations.CreateDashboardReportPaperTrail do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create_version_table(
      :authored_dashboard_versions,
      :authored_dashboards,
      "authored_dashboard_versions_source_fkey"
    )

    create_version_table(
      :dashboard_report_schedule_versions,
      :dashboard_report_schedules,
      "dashboard_report_schedule_versions_source_fkey"
    )
  end

  def down do
    drop_if_exists(
      index(:dashboard_report_schedule_versions, [:version_source_id], prefix: @prefix)
    )

    drop_if_exists(table(:dashboard_report_schedule_versions, prefix: @prefix))
    drop_if_exists(index(:authored_dashboard_versions, [:version_source_id], prefix: @prefix))
    drop_if_exists(table(:authored_dashboard_versions, prefix: @prefix))
  end

  defp create_version_table(table, source_table, fkey_name) do
    create table(table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})

      add(
        :version_source_id,
        references(source_table,
          type: :uuid,
          name: fkey_name,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(table, [:version_source_id],
        name: String.to_atom("#{table}_source_idx"),
        prefix: @prefix
      )
    )
  end
end
