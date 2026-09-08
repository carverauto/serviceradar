defmodule ServiceRadar.Repo.Migrations.MarkImplausiblePercentCapacityForecastsSkipped do
  @moduledoc """
  Reclassifies historical percent-capacity forecasts whose projected value is
  outside the physical [0, 100] domain, or whose model produced no exhaustion
  crossing while the resource is still below threshold.

  The bounded capacity kernel and worker policy prevent new invalid/no-risk percent
  projections. This cleanup keeps existing stale rows from continuing to appear as
  runway risks in SRQL or fleet views after the fix is deployed.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{schema()}.capacity_forecasts
    SET
      status = 'skipped',
      skip_reason = COALESCE(
        skip_reason,
        CASE
          WHEN projected_value < 0.0 OR projected_value > 100.0
            THEN 'implausible_percent_projection'
          ELSE 'no_projected_exhaustion'
        END
      ),
      projected_exhaustion_at = NULL,
      metadata = jsonb_set(
        jsonb_set(
          jsonb_set(
            metadata,
            '{diagnostics,implausible_percent_projection}',
            to_jsonb((projected_value < 0.0 OR projected_value > 100.0)),
            true
          ),
          '{diagnostics,no_projected_exhaustion}',
          to_jsonb(
            projected_exhaustion_at IS NULL
            AND current_value IS NOT NULL
            AND exhaustion_threshold IS NOT NULL
            AND current_value < exhaustion_threshold
          ),
          true
        ),
        '{diagnostics,cleanup_migration}',
        to_jsonb('20260627094500_mark_implausible_percent_capacity_forecasts_skipped'::text),
        true
      ),
      updated_at = now()
    WHERE
      status = 'projected'
      AND projected_value IS NOT NULL
      AND (
        metric_name IN ('usage_percent', 'utilization_percent')
        OR metadata->>'forecast_value_unit' IN ('%', 'percent', 'percentage')
        OR metadata->>'raw_value_unit' IN ('%', 'percent', 'percentage')
      )
      AND (
        projected_value < 0.0
        OR projected_value > 100.0
        OR (
          projected_exhaustion_at IS NULL
          AND current_value IS NOT NULL
          AND exhaustion_threshold IS NOT NULL
          AND current_value < exhaustion_threshold
        )
      )
    """)
  end

  def down do
    :ok
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
