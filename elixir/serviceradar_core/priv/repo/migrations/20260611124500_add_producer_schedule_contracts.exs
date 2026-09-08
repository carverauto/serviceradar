defmodule ServiceRadar.Repo.Migrations.AddProducerScheduleContracts do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:plugin_packages, prefix: "platform") do
      add(:producer_schedules, {:array, :map}, null: false, default: [])
    end

    alter table(:addon_packages, prefix: "platform") do
      add(:producer_schedules, {:array, :map}, null: false, default: [])
    end

    create table(:producer_schedules, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:producer_kind, :text, null: false)

      add(
        :plugin_package_id,
        references(:plugin_packages, type: :uuid, on_delete: :delete_all, prefix: "platform")
      )

      add(
        :addon_package_id,
        references(:addon_packages, type: :uuid, on_delete: :delete_all, prefix: "platform")
      )

      add(
        :plugin_assignment_id,
        references(:plugin_assignments, type: :uuid, on_delete: :nilify_all, prefix: "platform")
      )

      add(
        :addon_assignment_id,
        references(:addon_assignments, type: :uuid, on_delete: :nilify_all, prefix: "platform")
      )

      add(:schedule_id, :text, null: false)
      add(:display_name, :text, null: false)
      add(:description, :text)
      add(:contract, :map, null: false, default: %{})
      add(:enabled, :boolean, null: false, default: false)
      add(:schedule_type, :text, null: false, default: "interval")
      add(:cadence_seconds, :integer, null: false, default: 86_400)
      add(:cron_expression, :text)
      add(:timezone, :text, null: false, default: "Etc/UTC")
      add(:target_query, :text)
      add(:params, :map, null: false, default: %{})
      add(:credential_refs, :map, null: false, default: %{})
      add(:last_run_at, :utc_datetime_usec)
      add(:next_due_at, :utc_datetime_usec)
      add(:last_command_id, :uuid)
      add(:last_status, :text, null: false, default: "never")
      add(:last_error, :text)
      add(:metadata, :map, null: false, default: %{})

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
      index(:producer_schedules, [:enabled, :next_due_at],
        name: "producer_schedules_due_idx",
        prefix: "platform"
      )
    )

    create(
      index(:producer_schedules, [:producer_kind, :schedule_id],
        name: "producer_schedules_kind_schedule_idx",
        prefix: "platform"
      )
    )

    create(
      unique_index(:producer_schedules, [:plugin_package_id, :schedule_id],
        name: "producer_schedules_plugin_package_uidx",
        prefix: "platform",
        where: "plugin_package_id IS NOT NULL"
      )
    )

    create(
      unique_index(:producer_schedules, [:addon_package_id, :schedule_id],
        name: "producer_schedules_addon_package_uidx",
        prefix: "platform",
        where: "addon_package_id IS NOT NULL"
      )
    )

    create(
      constraint(:producer_schedules, :producer_schedules_one_package_chk,
        prefix: "platform",
        check:
          "(producer_kind = 'wasm_plugin' AND plugin_package_id IS NOT NULL AND addon_package_id IS NULL) OR " <>
            "(producer_kind = 'native_addon' AND addon_package_id IS NOT NULL AND plugin_package_id IS NULL)"
      )
    )

    create(
      constraint(:producer_schedules, :producer_schedules_type_chk,
        prefix: "platform",
        check: "schedule_type IN ('interval', 'cron', 'manual')"
      )
    )

    create(
      constraint(:producer_schedules, :producer_schedules_cadence_chk,
        prefix: "platform",
        check: "cadence_seconds > 0"
      )
    )
  end

  def down do
    drop(table(:producer_schedules, prefix: "platform"))

    alter table(:addon_packages, prefix: "platform") do
      remove(:producer_schedules)
    end

    alter table(:plugin_packages, prefix: "platform") do
      remove(:producer_schedules)
    end
  end
end
