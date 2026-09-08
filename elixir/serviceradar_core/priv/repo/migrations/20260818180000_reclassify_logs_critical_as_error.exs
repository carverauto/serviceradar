defmodule ServiceRadar.Repo.Migrations.ReclassifyLogsCriticalAsError do
  @moduledoc """
  Treats severity_text `critical` as error, not fatal.

  Falco and Trivy emit `Critical` as a priority / CVE severity. The Falco
  processor already maps that to OTEL severity_number 20 (error). The log
  cards still counted those rows as Fatal because
  `serviceradar_log_severity_bucket` listed `critical` with `fatal` /
  `emergency` / `alert`.

  Syslog emergency/alert/critical (levels 0-2) continue to land in Fatal:
  the bundled `syslog_severity` Zen rule rewrites those to severity_text
  `FATAL` and severity_number 21 before insert.

  Stored CAGG buckets do not change until the next 24-hour refresh. The
  worker watermark `logs_severity_stats_5m_v3_critical_as_error` forces
  that refill after deploy.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @classifier "platform.serviceradar_log_severity_bucket"

  def up do
    # serviceradar:allow-startup-maintenance - replaces an IMMUTABLE SQL
    # function; no table rewrite. The Oban worker refills the 24-hour CAGG.
    execute("""
    CREATE OR REPLACE FUNCTION #{@classifier}(
      severity_text text,
      severity_number integer
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT CASE
        WHEN lower(COALESCE(severity_text, '')) IN (
          'fatal',
          'emergency',
          'alert',
          'severity_number_fatal',
          'severity_number_fatal2',
          'severity_number_fatal3',
          'severity_number_fatal4'
        ) THEN 'fatal'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'error',
          'err',
          'critical',
          'severity_number_error',
          'severity_number_error2',
          'severity_number_error3',
          'severity_number_error4'
        ) THEN 'error'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'warning',
          'warn',
          'severity_number_warn',
          'severity_number_warn2',
          'severity_number_warn3',
          'severity_number_warn4'
        ) THEN 'warning'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'info',
          'information',
          'informational',
          'notice',
          'severity_number_info',
          'severity_number_info2',
          'severity_number_info3',
          'severity_number_info4'
        ) THEN 'info'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'debug',
          'trace',
          'severity_number_debug',
          'severity_number_debug2',
          'severity_number_debug3',
          'severity_number_debug4',
          'severity_number_trace',
          'severity_number_trace2',
          'severity_number_trace3',
          'severity_number_trace4'
        ) THEN 'debug'
        WHEN severity_number BETWEEN 21 AND 24 THEN 'fatal'
        WHEN severity_number BETWEEN 17 AND 20 THEN 'error'
        WHEN severity_number BETWEEN 13 AND 16 THEN 'warning'
        WHEN severity_number BETWEEN 9 AND 12 THEN 'info'
        WHEN severity_number BETWEEN 1 AND 8 THEN 'debug'
        ELSE NULL
      END
    $function$
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION #{@classifier}(
      severity_text text,
      severity_number integer
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT CASE
        WHEN lower(COALESCE(severity_text, '')) IN (
          'fatal',
          'critical',
          'emergency',
          'alert',
          'severity_number_fatal',
          'severity_number_fatal2',
          'severity_number_fatal3',
          'severity_number_fatal4'
        ) THEN 'fatal'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'error',
          'err',
          'severity_number_error',
          'severity_number_error2',
          'severity_number_error3',
          'severity_number_error4'
        ) THEN 'error'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'warning',
          'warn',
          'severity_number_warn',
          'severity_number_warn2',
          'severity_number_warn3',
          'severity_number_warn4'
        ) THEN 'warning'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'info',
          'information',
          'informational',
          'notice',
          'severity_number_info',
          'severity_number_info2',
          'severity_number_info3',
          'severity_number_info4'
        ) THEN 'info'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'debug',
          'trace',
          'severity_number_debug',
          'severity_number_debug2',
          'severity_number_debug3',
          'severity_number_debug4',
          'severity_number_trace',
          'severity_number_trace2',
          'severity_number_trace3',
          'severity_number_trace4'
        ) THEN 'debug'
        WHEN severity_number BETWEEN 21 AND 24 THEN 'fatal'
        WHEN severity_number BETWEEN 17 AND 20 THEN 'error'
        WHEN severity_number BETWEEN 13 AND 16 THEN 'warning'
        WHEN severity_number BETWEEN 9 AND 12 THEN 'info'
        WHEN severity_number BETWEEN 1 AND 8 THEN 'debug'
        ELSE NULL
      END
    $function$
    """)
  end
end
