defmodule ServiceRadar.Inventory.Identity.MacIdentifierBackfillTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.MacIdentifierBackfill

  defp device(uid, mac, opts \\ []) do
    %{
      uid: uid,
      mac: mac,
      hostname: Keyword.get(opts, :hostname),
      ip: Keyword.get(opts, :ip),
      discovery_sources: Keyword.get(opts, :sources, ["sweep"]),
      partitions: Keyword.get(opts, :partitions, [])
    }
  end

  defp plan(devices, owners \\ %{}) do
    MacIdentifierBackfill.plan(devices, existing_loader: fn _keys -> {:ok, owners} end)
  end

  test "registers a MAC that lives on the device row but was never registered" do
    # The whole point: DIRE matches on registered identifiers, so this device is
    # invisible to MAC-based convergence until the row exists.
    assert {:ok, %{entries: [entry], summary: summary}} =
             plan([device("sr:a", "ac:8b:a9:d5:87:dd", hostname: "U6 Mesh")])

    assert entry.status == :ready
    assert entry.identifier_value == "AC8BA9D587DD"
    assert entry.partition == "default"
    assert summary.ready == 1
  end

  test "fails closed when two devices claim the same MAC" do
    # Never tie-break: binding either way merges two devices.
    assert {:ok, %{entries: entries, summary: summary}} =
             plan([device("sr:a", "aa:bb:cc:dd:ee:ff"), device("sr:b", "AA-BB-CC-DD-EE-FF")])

    assert summary.ready == 0
    assert summary.skipped == 2

    for entry <- entries do
      assert entry.status == :skipped
      assert entry.reason == :mac_claimed_by_multiple_devices
      assert entry.conflicting_device_uids == ["sr:a", "sr:b"]
    end
  end

  test "reports a conflict and never rebinds a MAC another device already owns" do
    owners = %{{"default", "AC8BA9D587DD"} => "sr:other"}

    assert {:ok, %{entries: [entry], summary: summary}} =
             plan([device("sr:a", "ac:8b:a9:d5:87:dd")], owners)

    assert entry.status == :conflict
    assert entry.reason == :identifier_owned_by_another_device
    assert entry.existing_owner_uid == "sr:other"
    assert summary.conflicts == 1
    assert summary.ready == 0
  end

  test "is idempotent for a MAC the same device already owns" do
    owners = %{{"default", "AC8BA9D587DD"} => "sr:a"}

    assert {:ok, %{entries: [entry], summary: summary}} =
             plan([device("sr:a", "ac:8b:a9:d5:87:dd")], owners)

    assert entry.status == :already_registered
    assert entry.reason == :same_owner
    assert summary.already_registered == 1
  end

  test "locally-administered MACs are registered at reduced confidence" do
    # Randomized phone Wi-Fi and virtual bridges are not globally unique, so they
    # must not carry the same weight as an OUI-assigned address.
    assert {:ok, %{entries: [local]}} = plan([device("sr:a", "1e:14:04:92:15:a9")])
    assert {:ok, %{entries: [global]}} = plan([device("sr:b", "1c:b3:c9:12:6c:6c")])

    refute local.confidence == global.confidence
    assert global.confidence == :strong
  end

  test "skips devices whose MAC cannot be normalized rather than registering junk" do
    assert {:ok, %{entries: [entry], summary: summary}} = plan([device("sr:a", "not-a-mac")])

    assert entry.status == :skipped
    assert entry.reason == :invalid_or_missing_mac
    assert summary.ready == 0
  end

  test "dry run performs no writes" do
    devices = [device("sr:a", "ac:8b:a9:d5:87:dd")]

    assert {:ok, report} =
             MacIdentifierBackfill.run(
               mode: :dry_run,
               device_loader: fn _limit, _after -> {:ok, devices} end,
               existing_loader: fn _keys -> {:ok, %{}} end,
               registrar: fn _entry, _actor -> flunk("dry run must not register") end
             )

    assert report.mode == :dry_run
    assert report.summary.ready == 1
    assert report.summary.registered == 0
  end

  test "execute registers only ready entries and leaves conflicts alone" do
    devices = [device("sr:a", "ac:8b:a9:d5:87:dd"), device("sr:b", "1c:b3:c9:12:6c:6c")]
    owners = %{{"default", "1CB3C9126C6C"} => "sr:someone-else"}
    test_pid = self()

    assert {:ok, report} =
             MacIdentifierBackfill.run(
               mode: :execute,
               device_loader: fn _limit, _after -> {:ok, devices} end,
               existing_loader: fn _keys -> {:ok, owners} end,
               registrar: fn entry, _actor ->
                 send(test_pid, {:registered, entry.identifier_value})
                 :ok
               end
             )

    assert report.summary.registered == 1
    assert report.summary.conflicts == 1
    assert_received {:registered, "AC8BA9D587DD"}
    refute_received {:registered, "1CB3C9126C6C"}
  end

  test "a device carrying several MACs yields one candidate per MAC" do
    assert {:ok, %{entries: entries}} =
             plan([device("sr:a", "ac:8b:a9:d5:87:dd,1c:b3:c9:12:6c:6c")])

    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.status == :ready))
    assert Enum.sort(Enum.map(entries, & &1.identifier_value)) == ["1CB3C9126C6C", "AC8BA9D587DD"]
  end
end
