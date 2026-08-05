defmodule ServiceRadar.Repo.Migrations.CreatePublicEndpointsCurrent do
  @moduledoc """
  Current-state inventory of Kubernetes public/edge endpoints (LoadBalancer,
  Gateway API, ExternalIP) produced by serviceradar-k8s-inventory.
  """
  use Ecto.Migration

  @table "public_endpoints_current"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      endpoint_key       TEXT        NOT NULL,
      cluster_id         TEXT        NOT NULL,
      ip                 TEXT,
      hostname           TEXT,
      port               INTEGER     NOT NULL,
      protocol           TEXT        NOT NULL DEFAULT 'TCP',
      exposure_class     TEXT        NOT NULL,
      external_traffic_policy TEXT,
      metallb_pool       TEXT,
      load_balancer_ip_mode TEXT,
      namespace           TEXT        NOT NULL DEFAULT '',
      service_name       TEXT        NOT NULL DEFAULT '',
      service_uid        TEXT,
      gateway_name       TEXT        NOT NULL DEFAULT '',
      gateway_class      TEXT,
      listener_name      TEXT        NOT NULL DEFAULT '',
      route_kind         TEXT        NOT NULL DEFAULT '',
      route_name         TEXT        NOT NULL DEFAULT '',
      service_target_port INTEGER,
      service_target_name TEXT,
      backend_refs       JSONB       NOT NULL DEFAULT '[]'::jsonb,
      endpoint_targets   JSONB       NOT NULL DEFAULT '[]'::jsonb,
      annotations        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      observed_at        TIMESTAMPTZ NOT NULL,
      snapshot_at        TIMESTAMPTZ NOT NULL,
      deleted_at         TIMESTAMPTZ,
      inserted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT public_endpoints_current_pkey PRIMARY KEY (endpoint_key)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_public_endpoints_current_cluster_ip
      ON #{schema}.#{@table} (cluster_id, ip)
      WHERE deleted_at IS NULL AND ip IS NOT NULL AND ip <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_public_endpoints_current_cluster_hostname
      ON #{schema}.#{@table} (cluster_id, hostname)
      WHERE deleted_at IS NULL AND hostname IS NOT NULL AND hostname <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_public_endpoints_current_port
      ON #{schema}.#{@table} (port, protocol)
      WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_public_endpoints_current_namespace_service
      ON #{schema}.#{@table} (namespace, service_name)
      WHERE deleted_at IS NULL
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
