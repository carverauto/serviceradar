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
end
