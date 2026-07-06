defmodule ServiceRadarWebNG.TenantUsageTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.TenantUsage

  test "managed device count excludes inactive devices" do
    baseline = TenantUsage.managed_device_count()
    unique = System.unique_integer([:positive])

    Repo.insert_all("ocsf_devices", [
      %{
        uid: "tenant-active-#{unique}",
        hostname: "tenant-active",
        type_id: 0,
        is_managed: true,
        is_active: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: "tenant-inactive-#{unique}",
        hostname: "tenant-inactive",
        type_id: 0,
        is_managed: true,
        is_active: false,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: "tenant-unmanaged-#{unique}",
        hostname: "tenant-unmanaged",
        type_id: 0,
        is_managed: false,
        is_active: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    assert TenantUsage.managed_device_count() == baseline + 1
  end

  test "leaf node count tracks provisioned runtime leaf servers" do
    baseline = TenantUsage.leaf_node_count()
    unique = System.unique_integer([:positive])
    ready_site_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    pending_site_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    Repo.insert_all("edge_sites", [
      %{
        id: ready_site_id,
        name: "Ready Leaf #{unique}",
        slug: "ready-leaf-#{unique}",
        status: "active"
      },
      %{
        id: pending_site_id,
        name: "Pending Leaf #{unique}",
        slug: "pending-leaf-#{unique}",
        status: "pending"
      }
    ])

    Repo.insert_all("nats_leaf_servers", [
      %{
        edge_site_id: ready_site_id,
        status: "connected",
        upstream_url: "tls://nats.example.test:7422",
        local_listen: "0.0.0.0:4222"
      },
      %{
        edge_site_id: pending_site_id,
        status: "pending",
        upstream_url: "tls://nats.example.test:7422",
        local_listen: "0.0.0.0:4222"
      }
    ])

    assert TenantUsage.leaf_node_count() == baseline + 1
  end
end
