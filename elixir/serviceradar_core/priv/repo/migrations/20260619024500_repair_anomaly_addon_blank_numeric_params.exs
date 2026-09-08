defmodule ServiceRadar.Repo.Migrations.RepairAnomalyAddonBlankNumericParams do
  @moduledoc """
  Repairs anomaly add-on assignments/profiles that persisted blank numeric
  config values, then clears stale circuit-open status rows caused by the
  rejected runtime config.

  Blank numeric params are semantically unset. Keeping them in persisted JSON
  caused older anomaly add-ons to reject Configure with `invalid type: string "",
  expected u64/f64`, after which the agent-side restart circuit stayed open
  until a fresh config was delivered.
  """

  use Ecto.Migration

  @addon_id "anomaly"
  @numeric_param_keys ~w(
    window_size
    min_samples
    n_sigma
    confirm_slots
    max_series
    min_std_floor
    min_cv
    checkpoint_max_age_secs
  )

  def up do
    clear_blank_config_circuit_open_statuses()

    Enum.each(@numeric_param_keys, fn key ->
      remove_blank_numeric_param("addon_assignments", key)
      remove_blank_numeric_param("addon_profiles", key)
    end)
  end

  def down do
    # Data repair only. Reintroducing blank numeric params would recreate the
    # runtime Configure failure this migration fixes.
    :ok
  end

  defp clear_blank_config_circuit_open_statuses do
    execute("""
    DELETE FROM platform.addon_statuses AS status
    WHERE status.addon_id = '#{@addon_id}'
      AND status.state = 'circuit_open'
      AND EXISTS (
        SELECT 1
        FROM platform.addon_assignments AS assignment
        JOIN platform.addon_packages AS package ON package.id = assignment.addon_package_id
        WHERE assignment.agent_uid = status.agent_uid
          AND package.addon_id = '#{@addon_id}'
          AND (#{blank_numeric_predicate("assignment")})
      )
    """)
  end

  defp remove_blank_numeric_param(table_name, key) do
    execute("""
    UPDATE platform.#{table_name} AS target
    SET params = COALESCE(target.params::jsonb, '{}'::jsonb) - '#{key}',
        updated_at = now()
    FROM platform.addon_packages AS package
    WHERE target.addon_package_id = package.id
      AND package.addon_id = '#{@addon_id}'
      AND #{blank_numeric_key_predicate("target", key)}
    """)
  end

  defp blank_numeric_predicate(table_alias) do
    Enum.map_join(
      @numeric_param_keys,
      "\n          OR ",
      &blank_numeric_key_predicate(table_alias, &1)
    )
  end

  defp blank_numeric_key_predicate(table_alias, key) do
    """
    jsonb_typeof(COALESCE(#{table_alias}.params::jsonb, '{}'::jsonb)->'#{key}') = 'string'
    AND COALESCE(#{table_alias}.params::jsonb, '{}'::jsonb)->>'#{key}' = ''
    """
  end
end
