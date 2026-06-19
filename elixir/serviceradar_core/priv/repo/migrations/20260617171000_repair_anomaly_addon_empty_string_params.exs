defmodule ServiceRadar.Repo.Migrations.RepairAnomalyAddonEmptyStringParams do
  @moduledoc """
  Repairs anomaly add-on assignments that were reconciled with empty-string
  detector params before the profile reconciler started treating blanks as
  inherited runtime defaults.

  Only known edge scalar knobs are removed, and only when the persisted JSON
  value is blank. Explicit numeric/operator values and nested config such as
  `metric_feed` are preserved.
  """

  use Ecto.Migration

  @addon_id "anomaly"
  @affected_agents ["agent-k8s-cp2-worker1", "k8s-agent"]
  @blank_scalar_keys [
    "confirm_slots",
    "checkpoint_max_age_secs",
    "max_series",
    "min_cv",
    "min_samples",
    "min_std_floor",
    "n_sigma",
    "state_max_age_secs",
    "window_size"
  ]

  def up do
    repair_blank_scalar_params()
    clear_stale_circuit_open_statuses()
  end

  def down do
    # Data repair only. Reintroducing invalid empty-string detector params or
    # stale circuit-open observations would break recovered agents.
    :ok
  end

  defp repair_blank_scalar_params do
    execute("""
    UPDATE platform.addon_assignments AS assignment
    SET params = (
          SELECT COALESCE(jsonb_object_agg(entry.key, entry.value), '{}'::jsonb)
          FROM jsonb_each(COALESCE(assignment.params::jsonb, '{}'::jsonb)) AS entry(key, value)
          WHERE NOT (
            entry.key = ANY (ARRAY[#{quoted_csv(@blank_scalar_keys)}])
            AND jsonb_typeof(entry.value) = 'string'
            AND btrim(entry.value #>> '{}') = ''
          )
        ),
        updated_at = now()
    FROM platform.addon_packages AS package
    WHERE assignment.addon_package_id = package.id
      AND assignment.agent_uid = ANY (ARRAY[#{quoted_csv(@affected_agents)}])
      AND (assignment.addon_id = '#{@addon_id}' OR package.addon_id = '#{@addon_id}')
      AND EXISTS (
        SELECT 1
        FROM jsonb_each(COALESCE(assignment.params::jsonb, '{}'::jsonb)) AS entry(key, value)
        WHERE entry.key = ANY (ARRAY[#{quoted_csv(@blank_scalar_keys)}])
          AND jsonb_typeof(entry.value) = 'string'
          AND btrim(entry.value #>> '{}') = ''
      )
    """)
  end

  defp clear_stale_circuit_open_statuses do
    execute("""
    DELETE FROM platform.addon_statuses AS status
    WHERE status.agent_uid = ANY (ARRAY[#{quoted_csv(@affected_agents)}])
      AND status.addon_id = '#{@addon_id}'
      AND status.state = 'circuit_open'
    """)
  end

  defp quoted_csv(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(", ")
  end
end
