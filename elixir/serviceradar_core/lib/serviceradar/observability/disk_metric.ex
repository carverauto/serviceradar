defmodule ServiceRadar.Observability.DiskMetric do
  @moduledoc """
  Disk utilization metric resource.

  Maps to the `disk_metrics` table for storing disk usage data.
  Uses TimescaleDB hypertable for efficient time-series storage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "disk_metric"

    routes do
      base "/disk_metrics"

      index :read
    end
  end

  postgres do
    table "disk_metrics"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
    end

    # Disk identification
    attribute :mount_point, :string do
      public? true
      description "Filesystem mount point"
    end

    attribute :device_name, :string do
      public? true
      description "Block device name"
    end

    attribute :filesystem_type, :string do
      public? true
      description "Filesystem type (ext4, xfs, etc.)"
    end

    # Disk metrics (in bytes)
    attribute :total_bytes, :integer do
      public? true
      description "Total disk space in bytes"
    end

    attribute :used_bytes, :integer do
      public? true
      description "Used disk space in bytes"
    end

    attribute :free_bytes, :integer do
      public? true
      description "Free disk space in bytes"
    end

    attribute :used_pct, :float do
      public? true
      description "Disk usage percentage"
    end

    # Inode metrics
    attribute :inodes_total, :integer do
      public? true
    end

    attribute :inodes_used, :integer do
      public? true
    end

    attribute :inodes_free, :integer do
      public? true
    end

    # Device references
    attribute :uid, :string do
      public? true
    end

    attribute :host_id, :string do
      public? true
    end

    attribute :poller_id, :string do
      public? true
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :uid, :string, allow_nil?: false
      filter expr(uid == ^arg(:uid))
    end

    read :by_mount_point do
      argument :mount_point, :string, allow_nil?: false
      filter expr(mount_point == ^arg(:mount_point))
    end

    read :recent do
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp, :mount_point, :device_name, :filesystem_type,
        :total_bytes, :used_bytes, :free_bytes, :used_pct,
        :inodes_total, :inodes_used, :inodes_free,
        :uid, :host_id, :poller_id, :agent_id, :partition
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(
        ^actor(:role) in [:viewer, :operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    policy action(:create) do
      authorize_if expr(
        ^actor(:role) in [:operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
