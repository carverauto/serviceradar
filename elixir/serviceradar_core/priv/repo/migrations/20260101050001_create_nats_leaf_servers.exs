defmodule ServiceRadar.Repo.Migrations.CreateNatsLeafServers do
  @moduledoc """
  Creates the nats_leaf_servers table for tracking NATS leaf server deployments.

  Each edge site has one NATS leaf server that stores:
  - mTLS certificates for upstream (leaf -> SaaS) connection
  - Server certificates for local (collector -> leaf) connections
  - Configuration tracking for drift detection
  """

  use Ecto.Migration

  def up do
    create table(:nats_leaf_servers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false
      add :edge_site_id, references(:edge_sites, type: :uuid, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "pending"
      add :upstream_url, :string, null: false
      add :local_listen, :string, null: false, default: "0.0.0.0:4222"

      # Leaf certificates (for upstream mTLS connection)
      add :leaf_cert_pem, :text
      add :leaf_key_pem_ciphertext, :binary

      # Server certificates (for local client connections)
      add :server_cert_pem, :text
      add :server_key_pem_ciphertext, :binary

      # CA chain (tenant CA + root CA)
      add :ca_chain_pem, :text

      # Configuration tracking
      add :config_checksum, :string
      add :cert_expires_at, :utc_datetime_usec

      # Timestamps
      add :provisioned_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:nats_leaf_servers, [:tenant_id])
    create unique_index(:nats_leaf_servers, [:edge_site_id])
    create index(:nats_leaf_servers, [:status])
  end

  def down do
    drop table(:nats_leaf_servers)
  end
end
