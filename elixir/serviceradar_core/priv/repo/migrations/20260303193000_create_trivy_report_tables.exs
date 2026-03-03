defmodule ServiceRadar.Repo.Migrations.CreateTrivyReportTables do
  @moduledoc """
  Stores Trivy report envelopes and extracted findings for actionable querying.
  """
  use Ecto.Migration

  def up do
    schema_prefix = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema_prefix}.trivy_reports (
      event_uuid         UUID        NOT NULL,
      observed_at        TIMESTAMPTZ NOT NULL,
      log_uuid           UUID,
      report_kind        TEXT        NOT NULL,
      cluster_id         TEXT,
      namespace          TEXT,
      name               TEXT,
      uid                TEXT,
      resource_version   TEXT,
      resource_kind      TEXT,
      resource_name      TEXT,
      resource_namespace TEXT,
      pod_name           TEXT,
      pod_namespace      TEXT,
      pod_uid            TEXT,
      pod_ip             TEXT,
      host_ip            TEXT,
      node_name          TEXT,
      container_name     TEXT,
      owner_kind         TEXT,
      owner_name         TEXT,
      owner_uid          TEXT,
      severity_id        INTEGER     NOT NULL DEFAULT 0,
      severity_text      TEXT,
      status_id          INTEGER     NOT NULL DEFAULT 99,
      findings_count     INTEGER     NOT NULL DEFAULT 0,
      summary            JSONB       NOT NULL DEFAULT '{}'::jsonb,
      owner_ref          JSONB       NOT NULL DEFAULT '{}'::jsonb,
      correlation        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      report_metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
      report_payload     JSONB       NOT NULL DEFAULT '{}'::jsonb,
      raw_payload        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (event_uuid)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema_prefix}.trivy_findings (
      finding_uuid       UUID        NOT NULL DEFAULT gen_random_uuid(),
      event_uuid         UUID        NOT NULL REFERENCES #{schema_prefix}.trivy_reports(event_uuid) ON DELETE CASCADE,
      observed_at        TIMESTAMPTZ NOT NULL,
      report_kind        TEXT        NOT NULL,
      cluster_id         TEXT,
      namespace          TEXT,
      resource_name      TEXT,
      pod_name           TEXT,
      pod_ip             TEXT,
      finding_type       TEXT        NOT NULL,
      finding_id         TEXT,
      target             TEXT,
      title              TEXT,
      severity_text      TEXT,
      severity_id        INTEGER     NOT NULL DEFAULT 0,
      status             TEXT,
      package_name       TEXT,
      installed_version  TEXT,
      fixed_version      TEXT,
      description        TEXT,
      references         JSONB       NOT NULL DEFAULT '[]'::jsonb,
      raw_finding        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      fingerprint        TEXT        NOT NULL,
      created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (finding_uuid),
      CONSTRAINT trivy_findings_fingerprint_unique UNIQUE (fingerprint)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_observed_at
      ON #{schema_prefix}.trivy_reports (observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_report_kind
      ON #{schema_prefix}.trivy_reports (report_kind)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_resource
      ON #{schema_prefix}.trivy_reports (resource_namespace, resource_kind, resource_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_pod_ip
      ON #{schema_prefix}.trivy_reports (pod_ip)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_severity
      ON #{schema_prefix}.trivy_reports (severity_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_payload_gin
      ON #{schema_prefix}.trivy_reports
      USING GIN (report_payload jsonb_path_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_name_trgm
      ON #{schema_prefix}.trivy_reports
      USING GIN (name gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_reports_search_tsv
      ON #{schema_prefix}.trivy_reports
      USING GIN (
        to_tsvector(
          'simple',
          concat_ws(
            ' ',
            coalesce(report_kind, ''),
            coalesce(resource_kind, ''),
            coalesce(resource_namespace, ''),
            coalesce(resource_name, ''),
            coalesce(pod_name, ''),
            coalesce(container_name, ''),
            coalesce(name, '')
          )
        )
      )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_event_uuid
      ON #{schema_prefix}.trivy_findings (event_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_observed_at
      ON #{schema_prefix}.trivy_findings (observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_pod_ip
      ON #{schema_prefix}.trivy_findings (pod_ip)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_severity
      ON #{schema_prefix}.trivy_findings (severity_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_finding_id
      ON #{schema_prefix}.trivy_findings (finding_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_raw_gin
      ON #{schema_prefix}.trivy_findings
      USING GIN (raw_finding jsonb_path_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_title_trgm
      ON #{schema_prefix}.trivy_findings
      USING GIN (title gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_search_tsv
      ON #{schema_prefix}.trivy_findings
      USING GIN (
        to_tsvector(
          'simple',
          concat_ws(
            ' ',
            coalesce(report_kind, ''),
            coalesce(finding_type, ''),
            coalesce(finding_id, ''),
            coalesce(title, ''),
            coalesce(description, ''),
            coalesce(package_name, ''),
            coalesce(resource_name, ''),
            coalesce(pod_name, '')
          )
        )
      )
    """)
  end

  def down do
    schema_prefix = prefix() || "platform"

    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_search_tsv")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_title_trgm")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_raw_gin")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_finding_id")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_severity")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_pod_ip")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_observed_at")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_event_uuid")

    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_search_tsv")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_name_trgm")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_payload_gin")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_severity")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_pod_ip")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_resource")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_report_kind")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_reports_observed_at")

    execute("DROP TABLE IF EXISTS #{schema_prefix}.trivy_findings")
    execute("DROP TABLE IF EXISTS #{schema_prefix}.trivy_reports")
  end
end
