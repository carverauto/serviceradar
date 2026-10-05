defmodule ServiceRadar.DeviceUpsertBindParameterLimitIntegrationTest do
  @moduledoc false
  # Postgres rejects any single statement binding more than 65,535 parameters
  # ("postgresql protocol can not handle N parameters, the maximum is 65535").
  # The sync device upsert is one insert_all per batch; a batch wide and large
  # enough to cross the line used to fail whole, killing the source's sync.
  # It must land in chunks instead.
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Inventory.Sync.DeviceWrites
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "a batch crossing the bound-parameter limit lands in chunks" do
    records = wide_device_records(2_800)

    # 2,800 rows x 24 bound columns = 67,200 parameters: over the 65,535
    # limit as one statement, under it as two chunks.
    assert {:ok, remap} = DeviceWrites.bulk_upsert_devices(records)
    assert remap == %{}

    landed = Repo.aggregate(device_uid_query(records), :count)
    assert landed == length(records)
  end

  defp device_uid_query(records) do
    import Ecto.Query, only: [from: 2]

    uids = Enum.map(records, & &1.uid)
    from(d in "ocsf_devices", where: d.uid in ^uids, select: d.uid)
  end

  # The field set a sync batch's device records carry (Sync.DeviceRecords
  # template shape), with synthetic values. All rows use nil addresses so the
  # upsert exercises the insert path alone, without the active-IP machinery.
  defp wide_device_records(count) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    run = System.unique_integer([:positive])

    for i <- 1..count do
      %{
        uid: "param-limit-#{run}-#{i}",
        partition: "default",
        ip: nil,
        mac: nil,
        hostname: "host-#{i}",
        name: "host-#{i}",
        type: "host",
        type_id: 0,
        vendor_name: "Synthetic Vendor",
        model: "SR-#{rem(i, 100)}",
        os: %{},
        hw_info: %{},
        network_interfaces: [],
        is_available: true,
        is_managed: true,
        is_active: true,
        owner: nil,
        metadata: %{"run" => run},
        tags: %{},
        discovery_sources: ["param_limit_test"],
        first_seen_time: now,
        last_seen_time: now,
        created_time: now,
        modified_time: now
      }
    end
  end
end
