defmodule ServiceRadar.Inventory.Remediation.ArmisUnmergeTest do
  @moduledoc """
  DB-backed coverage for the `armis-unmerge` disposition step (OpenSpec
  `remediate-armis-overmerge-disposition`): dry-run plans without writing,
  execute splits a live mega-device per distinct universal MAC (survivor keeps
  the `armis_device_id`), restores a ghost tombstone and rescues its sole-copy
  MAC (TTL reset), writes `unmerge` audits + a rollback manifest, and re-runs
  idempotently.

  These tests run under the auto-commit sandbox (no per-test rollback), so every
  assertion is scoped to this test's own unique identifiers.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @ghost_reason "armis_source_device_id_ghost_cleanup"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:armis_unmerge_test)}
  end

  test "dry-run plans the split without writing; execute splits, rescues, audits; re-run is idempotent",
       %{actor: actor} do
    armis_id = unique("armis-mega")
    survivor_mac = universal_mac()
    other_macs = [universal_mac(), universal_mac()]
    local = local_mac()

    mega = seed_armis_device!(actor, armis_id, survivor_mac)
    register_mac!(actor, mega.uid, survivor_mac)
    Enum.each(other_macs, &register_mac!(actor, mega.uid, &1))
    register_mac!(actor, mega.uid, local)

    ghost_mac = universal_mac()
    ghost = seed_armis_device!(actor, unique("armis-ghost"), ghost_mac)
    register_mac!(actor, ghost.uid, ghost_mac)
    tombstone_as_ghost!(ghost.uid)
    backdate_identifier!(ghost_mac, days: 100)

    # -- dry run: plan only, no writes --------------------------------------
    assert {:ok, %{reports: %{"armis-unmerge" => dry}}} =
             DireRemediation.run(steps: ["armis-unmerge"], mode: :dry_run)

    mega_plan = Enum.find(dry.split_plan, &(&1.device_uid == mega.uid))
    assert mega_plan, "expected the seeded mega-device in the dry-run plan"
    assert mega_plan.survivor_mac == survivor_mac
    assert mega_plan.survivor_action == "adopt"
    assert mega_plan.new_device_count == 2
    assert Enum.sort(Enum.map(mega_plan.new_devices, & &1.mac)) == Enum.sort(other_macs)

    ghost_plan = Enum.find(dry.split_plan, &(&1.device_uid == ghost.uid))
    assert ghost_plan
    assert ghost_plan.tombstoned
    assert ghost_plan.survivor_action == "restore"
    assert ghost_plan.new_device_count == 0

    # Nothing written: MAC rows still on the mega-device, ghost still tombstoned.
    assert owner_of_mac(hd(other_macs)) == mega.uid
    assert tombstoned?(ghost.uid)

    # -- execute -------------------------------------------------------------
    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "armis_unmerge_test_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(manifest_path) end)

    assert {:ok, %{reports: %{"armis-unmerge" => report}}} =
             DireRemediation.run(
               steps: ["armis-unmerge"],
               mode: :execute,
               manifest_path: manifest_path
             )

    assert report.split_failures == 0
    assert report.applied_splits >= 2

    # Survivor: live, keeps its uid, its MAC class, the local MAC, and the
    # armis_device_id (exactly one owner -> no typed_id_on_multiple_devices).
    refute tombstoned?(mega.uid)
    assert owner_of_mac(survivor_mac) == mega.uid
    assert owner_of_mac(local) == mega.uid
    assert armis_id_owners(armis_id) == [mega.uid]

    # Each split class landed on a distinct new live device with a bumped TTL clock.
    split_owner_uids =
      for mac <- other_macs do
        owner = owner_of_mac(mac)
        assert owner != mega.uid
        refute tombstoned?(owner)
        assert recently_seen?(mac)
        owner
      end

    assert length(Enum.uniq(split_owner_uids)) == 2

    # Split devices carry NO armis identity (survivor-keeps-it disposition).
    for uid <- split_owner_uids do
      assert typed_armis_ids_on(uid) == []
    end

    # One unmerge audit per split, from the mega-device.
    assert unmerge_audit_count(mega.uid) == 2

    # Ghost: restored, sole-copy MAC still on it with a reset TTL clock.
    refute tombstoned?(ghost.uid)
    assert owner_of_mac(ghost_mac) == ghost.uid
    assert recently_seen?(ghost_mac)

    # Manifest records the mutations.
    manifest_lines = manifest_path |> File.read!() |> String.split("\n", trim: true)
    assert Enum.any?(manifest_lines, &(&1 =~ "create_device"))
    assert Enum.any?(manifest_lines, &(&1 =~ "reassign_identifier"))
    assert Enum.any?(manifest_lines, &(&1 =~ "restore_device"))
    assert Enum.any?(manifest_lines, &(&1 =~ "touch_identifier"))

    # Northbound: the survivor is still the (single) candidate for its armis id.
    candidates = Repo.all(ArmisNorthboundRunner.candidates_query(%{id: unique("nb-src")}))
    survivor_candidates = Enum.filter(candidates, &(&1.armis_device_id == armis_id))
    assert survivor_candidates |> Enum.map(& &1.device_id) |> Enum.uniq() == [mega.uid]

    # -- idempotent re-run ---------------------------------------------------
    assert {:ok, %{reports: %{"armis-unmerge" => rerun}}} =
             DireRemediation.run(steps: ["armis-unmerge"], mode: :execute)

    refute Enum.any?(
             rerun.split_plan,
             &(&1.device_uid in [mega.uid, ghost.uid | split_owner_uids])
           )

    assert armis_id_owners(armis_id) == [mega.uid]
    assert owner_of_mac(hd(other_macs)) in split_owner_uids
  end

  test "a local-only armis device is never a candidate and is left untouched", %{actor: actor} do
    armis_id = unique("armis-local-only")
    locals = [local_mac(), local_mac()]

    device = seed_armis_device!(actor, armis_id, nil)
    Enum.each(locals, &register_mac!(actor, device.uid, &1))

    assert {:ok, %{reports: %{"armis-unmerge" => report}}} =
             DireRemediation.run(steps: ["armis-unmerge"], mode: :dry_run)

    refute Enum.any?(report.split_plan, &(&1.device_uid == device.uid))
    assert Enum.all?(locals, &(owner_of_mac(&1) == device.uid))
  end

  # -- seeding helpers -------------------------------------------------------

  defp seed_armis_device!(actor, armis_id, mac) do
    device =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ecto.UUID.generate(),
          hostname: unique("unmerge-host"),
          mac: mac,
          discovery_sources: ["armis"],
          metadata: %{
            "integration_type" => "armis",
            "armis_device_id" => armis_id,
            "integration_id" => armis_id
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device.uid,
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default",
        confidence: :strong
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    device
  end

  defp register_mac!(actor, device_uid, mac) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: :mac,
        identifier_value: mac,
        partition: "default",
        confidence: :strong
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp tombstone_as_ghost!(uid) do
    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = timezone('utc', now()), " <>
        "deleted_reason = $2 WHERE uid = $1",
      [uid, @ghost_reason]
    )
  end

  defp backdate_identifier!(value, days: days) do
    Repo.query!(
      "UPDATE platform.device_identifiers SET last_seen = timezone('utc', now()) - " <>
        "make_interval(days => $2) WHERE identifier_type = 'mac' AND identifier_value = $1",
      [value, days]
    )
  end

  # -- assertion helpers ------------------------------------------------------

  defp owner_of_mac(mac) do
    Repo.one(
      from(di in DeviceIdentifier,
        where: di.identifier_type == :mac and di.identifier_value == ^mac,
        select: di.device_id
      )
    )
  end

  defp recently_seen?(mac) do
    last_seen =
      Repo.one(
        from(di in DeviceIdentifier,
          where: di.identifier_type == :mac and di.identifier_value == ^mac,
          select: di.last_seen
        )
      )

    DateTime.diff(DateTime.utc_now(), last_seen, :second) < 3_600
  end

  defp tombstoned?(uid) do
    %{rows: [[tombstoned]]} =
      Repo.query!("SELECT deleted_at IS NOT NULL FROM platform.ocsf_devices WHERE uid = $1", [uid])

    tombstoned
  end

  defp armis_id_owners(armis_id) do
    Repo.all(
      from(di in DeviceIdentifier,
        where: di.identifier_type == :armis_device_id and di.identifier_value == ^armis_id,
        select: di.device_id
      )
    )
  end

  defp typed_armis_ids_on(uid) do
    Repo.all(
      from(di in DeviceIdentifier,
        where: di.device_id == ^uid and di.identifier_type == :armis_device_id,
        select: di.identifier_value
      )
    )
  end

  defp unmerge_audit_count(from_uid) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.merge_audit WHERE from_device_id = $1 AND reason = 'unmerge'",
        [from_uid]
      )

    count
  end

  # Universal MAC: 2nd hex char "0" (0x02 bit clear). Local: "02" prefix.
  defp universal_mac do
    "00#{~c"~10.16.0B" |> :io_lib.format([System.unique_integer([:positive])]) |> to_string()}"
    |> String.slice(0, 12)
    |> String.upcase()
  end

  defp local_mac do
    "02#{~c"~10.16.0B" |> :io_lib.format([System.unique_integer([:positive])]) |> to_string()}"
    |> String.slice(0, 12)
    |> String.upcase()
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
