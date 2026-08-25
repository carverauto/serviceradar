defmodule ServiceRadar.Inventory.InterfaceCurrentStateTest do
  @moduledoc """
  Current-state persistence: one row per `(device_id, interface_uid)`, and the
  SNMP targeting count is a DEVICE count (GitHub #4021).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.RekeyDiscoveredInterfacesCurrentState
  alias ServiceRadar.TestSupport

  require Ash.Query

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260825030000_rekey_discovered_interfaces_current_state.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:interface_current_state_test)}
  end

  test "a second observation of the same interface upserts, it does not append", %{actor: actor} do
    {:ok, device} = create_device(actor)
    uid = "name:eth0"
    t1 = ~U[2026-08-25 00:00:00Z]
    t2 = ~U[2026-08-25 00:05:00Z]

    assert :ok = upsert_interface(device.uid, uid, t1, "192.168.1.1", actor)
    assert :ok = upsert_interface(device.uid, uid, t2, "192.168.1.1", actor)

    rows = interfaces_for(device.uid, actor)
    assert [%Interface{interface_uid: ^uid, timestamp: ^t2}] = rows
  end

  test "collapse keeps mapper if_index when a later sparse sync row would win" do
    suffix = System.unique_integer([:positive])
    src = "collapse_src_#{suffix}"
    dest = "collapse_dest_#{suffix}"
    device_id = "sr:collapse-#{suffix}"
    uid = "name:eth0"
    t1 = ~U[2026-08-25 00:00:00Z]
    t2 = ~U[2026-08-25 00:05:00Z]

    Repo.query!("""
    CREATE TEMP TABLE #{src} (
      device_id text NOT NULL,
      interface_uid text NOT NULL,
      timestamp timestamptz NOT NULL,
      created_at timestamptz,
      if_index integer,
      if_speed bigint,
      speed_bps bigint,
      if_admin_status integer,
      if_oper_status integer,
      if_type integer,
      mtu integer,
      duplex text,
      available_metrics jsonb[]
    )
    """)

    Repo.query!(
      """
      INSERT INTO #{src} (
        device_id, interface_uid, timestamp, created_at,
        if_index, if_speed, speed_bps, if_admin_status, if_oper_status,
        if_type, mtu, duplex, available_metrics
      ) VALUES
        ($1, $2, $3, $3, 17, 1000000000, 1000000000, 1, 1, 6, 1500, 'full',
         ARRAY['{"name":"ifInOctets"}'::jsonb]),
        ($1, $2, $4, $4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
      """,
      [device_id, uid, t1, t2]
    )

    Repo.query!("""
    CREATE TEMP TABLE #{dest} AS
    SELECT DISTINCT ON (device_id, interface_uid) *
    FROM #{src}
    ORDER BY device_id, interface_uid, timestamp DESC, created_at DESC NULLS LAST
    """)

    %{rows: [[nil]]} =
      Repo.query!("SELECT if_index FROM #{dest} WHERE device_id = $1", [device_id])

    Repo.query!(RekeyDiscoveredInterfacesCurrentState.coalesce_mapper_columns_sql(src, dest))

    %{rows: [[if_index, if_speed, duplex, available_metrics]]} =
      Repo.query!(
        "SELECT if_index, if_speed, duplex, available_metrics FROM #{dest} WHERE device_id = $1",
        [device_id]
      )

    assert if_index == 17
    assert if_speed == 1_000_000_000
    assert duplex == "full"
    assert available_metrics == [%{"name" => "ifInOctets"}]
  end

  test "a device with several matching interfaces counts once as an SNMP target", %{actor: actor} do
    {:ok, device} = create_device(actor)

    assert :ok = upsert_interface(device.uid, "name:eth0", DateTime.utc_now(), "10.0.0.1", actor)
    assert :ok = upsert_interface(device.uid, "name:eth1", DateTime.utc_now(), "10.0.0.2", actor)
    assert :ok = upsert_interface(device.uid, "name:eth2", DateTime.utc_now(), "10.0.0.3", actor)

    interface_count =
      Interface
      |> Ash.Query.filter(device_id == ^device.uid)
      |> Ash.count!(actor: actor)

    target_count =
      Interface
      |> Ash.Query.filter(device_id == ^device.uid)
      |> Ash.Query.distinct(:device_id)
      |> Ash.count!(actor: actor)

    assert interface_count == 3
    assert target_count == 1
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "iface-current-state",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  defp upsert_interface(device_id, interface_uid, timestamp, ip, actor) do
    record = %{
      timestamp: timestamp,
      device_id: device_id,
      interface_uid: interface_uid,
      device_ip: ip,
      if_name: interface_uid,
      ip_addresses: [ip],
      created_at: timestamp
    }

    result =
      Ash.bulk_create([record], Interface, :create,
        actor: actor,
        upsert?: true,
        upsert_identity: :unique_interface,
        upsert_fields: [:timestamp, :device_ip, :if_name, :ip_addresses]
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      other -> {:error, other}
    end
  end

  defp interfaces_for(device_id, actor) do
    Interface
    |> Ash.Query.filter(device_id == ^device_id)
    |> Ash.Query.sort(interface_uid: :asc)
    |> Ash.read!(actor: actor)
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    "100.82.#{rem(n, 200) + 1}.#{rem(div(n, 200), 200) + 1}"
  end
end
