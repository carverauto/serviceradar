defmodule ServiceRadar.Repo.Migrations.CreateSloMonitoringFoundation do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:service_level_indicators, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sli_key, :text, null: false)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:sli_type, :text, null: false)
      add(:source_type, :text, null: false, default: "check_state")
      add(:measurement_kind, :text, null: false, default: "request")
      add(:good_statuses, {:array, :text}, null: false, default: ["ok"])
      add(:metric_name, :text)
      add(:threshold_operator, :text)
      add(:threshold_value, :decimal, precision: 20, scale: 6)
      add(:threshold_unit, :text)
      add(:query_template, :text)
      add(:numerator_query, :text)
      add(:denominator_query, :text)
      add(:window_config, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "draft")
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

    create unique_index(:service_level_indicators, [:sli_key],
             prefix: @prefix,
             name: :service_level_indicators_sli_key_idx
           )

    create index(:service_level_indicators, [:sli_type, :status],
             prefix: @prefix,
             name: :service_level_indicators_type_status_idx
           )

    create_version_table(
      :service_level_indicator_versions,
      :service_level_indicators,
      "service_level_indicator_versions_version_source_id_fkey",
      :service_level_indicator_versions_source_idx
    )

    create table(:service_level_objectives, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:slo_key, :text, null: false)
      add(:name, :text, null: false)
      add(:description, :text)

      add(
        :sli_id,
        references(:service_level_indicators, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(:target_set_type, :text, null: false)

      add(
        :service_group_id,
        references(:service_groups, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:target_query, :text)
      add(:target_filters, :map, null: false, default: %{})
      add(:slo_kind, :text, null: false, default: "request_based")
      add(:goal_basis_points, :bigint, null: false)
      add(:compliance_period_type, :text, null: false, default: "rolling")
      add(:rolling_period_days, :bigint, default: 30)
      add(:calendar_period, :text)
      add(:measurement_window_seconds, :bigint)
      add(:burn_rate_policy, :map, null: false, default: %{})
      add(:alert_policy, :map, null: false, default: %{})
      add(:owner, :text)
      add(:status, :text, null: false, default: "draft")
      add(:last_evaluated_at, :utc_datetime)
      add(:last_compliance_state, :text)
      add(:last_budget_remaining_basis_points, :bigint)
      add(:last_burn_rate, :decimal, precision: 20, scale: 6)
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

    create unique_index(:service_level_objectives, [:slo_key],
             prefix: @prefix,
             name: :service_level_objectives_slo_key_idx
           )

    create index(:service_level_objectives, [:sli_id, :status],
             prefix: @prefix,
             name: :service_level_objectives_sli_status_idx
           )

    create index(:service_level_objectives, [:service_group_id],
             prefix: @prefix,
             name: :service_level_objectives_service_group_idx
           )

    create index(:service_level_objectives, [:owner, :status],
             prefix: @prefix,
             name: :service_level_objectives_owner_status_idx
           )

    create constraint(:service_level_objectives, :service_level_objectives_goal_has_budget,
             prefix: @prefix,
             check: "goal_basis_points >= 1 AND goal_basis_points < 10000"
           )

    create_version_table(
      :service_level_objective_versions,
      :service_level_objectives,
      "service_level_objective_versions_version_source_id_fkey",
      :service_level_objective_versions_source_idx
    )

    create table(:service_level_objective_evaluations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:evaluation_key, :text, null: false)

      add(
        :slo_id,
        references(:service_level_objectives,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:period_started_at, :utc_datetime, null: false)
      add(:period_ended_at, :utc_datetime, null: false)
      add(:evaluated_at, :utc_datetime, null: false)
      add(:compliance_state, :text, null: false, default: "unknown")
      add(:eligible_events, :bigint, null: false, default: 0)
      add(:good_events, :bigint, null: false, default: 0)
      add(:bad_events, :bigint, null: false, default: 0)
      add(:total_windows, :bigint, null: false, default: 0)
      add(:good_windows, :bigint, null: false, default: 0)
      add(:bad_windows, :bigint, null: false, default: 0)
      add(:compliance_basis_points, :bigint, null: false, default: 0)
      add(:goal_basis_points, :bigint, null: false)
      add(:error_budget_total, :bigint, null: false, default: 0)
      add(:error_budget_consumed, :bigint, null: false, default: 0)
      add(:error_budget_remaining, :bigint, null: false, default: 0)
      add(:budget_remaining_basis_points, :bigint, null: false, default: 0)
      add(:burn_rate_short, :decimal, precision: 20, scale: 6)
      add(:burn_rate_long, :decimal, precision: 20, scale: 6)
      add(:projected_exhaustion_at, :utc_datetime)
      add(:severity, :text, null: false, default: "info")

      add(:event_id, :uuid)
      add(:alert_id, references(:alerts, type: :uuid, on_delete: :nilify_all, prefix: @prefix))
      add(:details, :map, null: false, default: %{})
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

    create unique_index(:service_level_objective_evaluations, [:evaluation_key],
             prefix: @prefix,
             name: :slo_evaluations_evaluation_key_idx
           )

    create index(:service_level_objective_evaluations, [:slo_id, :evaluated_at],
             prefix: @prefix,
             name: :slo_evaluations_slo_evaluated_idx
           )

    create index(:service_level_objective_evaluations, [:compliance_state, :severity],
             prefix: @prefix,
             name: :slo_evaluations_state_severity_idx
           )

    create_version_table(
      :service_level_objective_evaluation_versions,
      :service_level_objective_evaluations,
      "slo_evaluation_versions_version_source_id_fkey",
      :slo_evaluation_versions_source_idx
    )
  end

  defp create_version_table(version_table, source_table, foreign_key_name, index_name) do
    create table(version_table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(source_table, type: :uuid, name: foreign_key_name, prefix: @prefix),
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

    create index(version_table, [:version_source_id], prefix: @prefix, name: index_name)
  end
end
