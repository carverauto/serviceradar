defmodule ServiceRadar.Inventory.Identity.IdentityRevisionSitesTest do
  @moduledoc """
  Identity-transition sites outside MergeEngine and the Device lifecycle actions.

  Each of these changes which identifiers a device owns without necessarily
  writing to `ocsf_devices` at all, so without an explicit bump the fence would
  fail open: the composition moves, the revision does not, and work holding a
  pinned revision keeps validating against an identity that has changed.

  The negative assertions matter as much as the positive ones. `CardinalityCaps.enforce/1`
  runs after every identifier write, so a bump on the no-op path would move the
  revision constantly and make every pinned read stale within seconds.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.CardinalityCaps
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:identity_revision_sites_test)}
  end

  describe "CardinalityCaps.enforce/1" do
    test "retiring identifiers over the cap bumps the revision", %{actor: actor} do
      {:ok, device} = create_device(actor)
      cap = CardinalityCaps.cap_for(:mac)

      # One past the cap, so exactly one identifier is retired.
      for _ <- 1..(cap + 1), do: register_mac(actor, device.uid)

      before = revision(actor, device.uid)
      assert :ok = CardinalityCaps.enforce([{device.uid, :mac}])

      assert revision(actor, device.uid) > before,
             "retiring an identifier changes which identifiers the device owns"
    end

    test "staying under the cap does not move the revision", %{actor: actor} do
      {:ok, device} = create_device(actor)
      register_mac(actor, device.uid)

      before = revision(actor, device.uid)
      assert :ok = CardinalityCaps.enforce([{device.uid, :mac}])

      assert revision(actor, device.uid) == before,
             "enforce/1 runs after every identifier write; a bump on the no-op path " <>
               "would make every pinned revision stale within seconds"
    end
  end

  describe "AliasGuard.invalidate_ip_alias/5" do
    test "staling an alias bumps the alias owner, not the conflicting device", %{actor: actor} do
      {:ok, alias_owner} = create_device(actor)
      {:ok, other} = create_device(actor)
      ip = unique_ip()

      {:ok, _} = create_alias_state(actor, alias_owner.uid, ip)

      owner_before = revision(actor, alias_owner.uid)
      other_before = revision(actor, other.uid)

      assert :ok =
               AliasGuard.invalidate_ip_alias(ip, "default", alias_owner.uid, other.uid, actor)

      assert revision(actor, alias_owner.uid) > owner_before,
             "the alias owner lost an identity value"

      assert revision(actor, other.uid) == other_before,
             "the conflicting device is only named in the log line; it did not change"
    end

    test "invalidating with no matching alias does not bump", %{actor: actor} do
      {:ok, alias_owner} = create_device(actor)
      {:ok, other} = create_device(actor)

      before = revision(actor, alias_owner.uid)

      assert :ok =
               AliasGuard.invalidate_ip_alias(
                 unique_ip(),
                 "default",
                 alias_owner.uid,
                 other.uid,
                 actor
               )

      assert revision(actor, alias_owner.uid) == before
    end
  end

  defp revision(actor, uid) do
    {:ok, %Device{identity_revision: revision}} = Device.get_by_uid(uid, true, actor: actor)
    revision
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "revision-sites-test",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  defp register_mac(actor, device_uid) do
    mac = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :upper)

    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: device_uid,
        identifier_type: :mac,
        identifier_value: mac,
        partition: "default",
        source: "test"
      })
      |> Ash.create(actor: actor)

    mac
  end

  defp create_alias_state(actor, device_uid, ip) do
    DeviceAliasState
    |> Ash.Changeset.for_create(:detect, %{
      device_id: device_uid,
      alias_type: :ip,
      alias_value: ip,
      partition: "default"
    })
    |> Ash.create(actor: actor)
  end

  defp unique_ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    "10.#{a}.#{b}.#{rem(c, 254) + 1}"
  end
end
