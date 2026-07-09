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
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Remediation.ArmisUnmerge
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Inventory.Remediation.Manifest
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
    config_key = DireRemediation
    previous_config = Application.get_env(:serviceradar_core, config_key, [])

    Application.put_env(
      :serviceradar_core,
      config_key,
      Keyword.put(previous_config, :enable_armis_unmerge_execute, true)
    )

    on_exit(fn -> Application.put_env(:serviceradar_core, config_key, previous_config) end)

    {:ok, actor: SystemActor.system(:armis_unmerge_test)}
  end

  test "dry-run plans the split without writing; execute splits, rescues, audits; re-run is idempotent",
       %{actor: actor} do
    armis_id = unique("armis-mega")
    survivor_mac = universal_mac()
    other_macs = [universal_mac(), universal_mac()]
    local = local_mac()
    source = create_source!(actor)

    mega = seed_armis_device!(actor, armis_id, survivor_mac, source.id)
    register_mac!(actor, mega.uid, survivor_mac)
    Enum.each(other_macs, &register_mac!(actor, mega.uid, &1))
    register_mac!(actor, mega.uid, local)
    register_identifier!(actor, mega.uid, :integration_id, unique("integration"))
    register_identifier!(actor, mega.uid, :integration_id, unique("integration"))

    ghost_mac = universal_mac()
    ghost = seed_armis_device!(actor, unique("armis-ghost"), ghost_mac)
    register_mac!(actor, ghost.uid, ghost_mac)
    tombstone_as_ghost!(ghost.uid)
    backdate_identifier!(ghost_mac, days: 100)

    # -- dry run: plan only, no writes --------------------------------------
    live_opts = [
      armis_unmerge_include_live: true,
      armis_unmerge_live_device_uids: [mega.uid],
      armis_unmerge_live_source_ids: [source.id]
    ]

    assert {:ok, %{reports: %{"armis-unmerge" => dry}}} =
             DireRemediation.run([steps: ["armis-unmerge"], mode: :dry_run] ++ live_opts)

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
               [
                 steps: ["armis-unmerge"],
                 mode: :execute,
                 manifest_path: manifest_path,
                 armis_unmerge_execute_enabled: true
               ] ++ live_opts
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
    candidates = Repo.all(ArmisNorthboundRunner.candidates_query(%{id: source.id}))
    survivor_candidates = Enum.filter(candidates, &(&1.armis_device_id == armis_id))
    assert survivor_candidates |> Enum.map(& &1.device_id) |> Enum.uniq() == [mega.uid]

    # -- idempotent re-run ---------------------------------------------------
    assert {:ok, %{reports: %{"armis-unmerge" => rerun}}} =
             DireRemediation.run(
               [
                 steps: ["armis-unmerge"],
                 mode: :execute,
                 armis_unmerge_execute_enabled: true
               ] ++ live_opts
             )

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

  test "direct execute is fail-closed when the runtime gate is absent", %{actor: actor} do
    source = create_source!(actor)
    armis_id = unique("armis-gated")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device = seed_verified_live_candidate!(actor, source.id, armis_id, survivor_mac, split_mac)

    config_key = DireRemediation
    config = Application.get_env(:serviceradar_core, config_key, [])

    Application.put_env(
      :serviceradar_core,
      config_key,
      Keyword.put(config, :enable_armis_unmerge_execute, false)
    )

    report =
      ArmisUnmerge.run(
        :execute,
        [armis_unmerge_execute_enabled: true],
        nil,
        actor
      )

    Application.put_env(:serviceradar_core, config_key, config)

    assert report.execution_blocked
    assert report.execution_blocked_reason == "armis_unmerge_execute_disabled"
    assert report.applied_splits == 0
    assert owner_of_mac(split_mac) == device.uid
  end

  test "execute scopes allowlisted live candidates before the batch limit", %{actor: actor} do
    source = create_source!(actor)

    excluded =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-excluded"),
        universal_mac(),
        universal_mac()
      )

    excluded_extra_mac = universal_mac()
    register_mac!(actor, excluded.uid, excluded_extra_mac)

    allowed_split_mac = universal_mac()

    allowed =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-allowed"),
        universal_mac(),
        allowed_split_mac
      )

    opts = [
      armis_unmerge_execute_enabled: true,
      armis_unmerge_include_live: true,
      armis_unmerge_live_device_uids: [allowed.uid],
      armis_unmerge_live_source_ids: [source.id],
      armis_unmerge_candidate_limit: 1
    ]

    dry = ArmisUnmerge.run(:dry_run, opts, nil, actor)
    assert Enum.map(dry.execution_split_plan, & &1.device_uid) == [allowed.uid]

    report = ArmisUnmerge.run(:execute, opts, nil, actor)

    assert report.applied_splits == 1
    assert owner_of_mac(allowed_split_mac) != allowed.uid
    assert owner_of_mac(excluded_extra_mac) == excluded.uid
  end

  test "invalid blob MAC rows are reported and block execution", %{actor: actor} do
    source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-blob-blocked"),
        universal_mac(),
        split_mac
      )

    register_mac!(actor, device.uid, "001AA0B94040,001422F42A2A")

    report =
      ArmisUnmerge.run(
        :execute,
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [device.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
        nil,
        actor
      )

    assert report.execution_blocked
    assert report.execution_blocked_reason == "blob_purge_precondition_failed"
    assert report.preconditions.invalid_mac_rows == 1
    assert owner_of_mac(split_mac) == device.uid
  end

  test "deterministic survivor selection also normalizes device display MACs", %{actor: actor} do
    source = create_source!(actor)
    armis_id = unique("armis-original-uid")
    original_mac = universal_mac()
    drifted_mac = universal_mac()

    original_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: original_mac,
        partition: "default"
      })

    device = seed_armis_device!(actor, armis_id, drifted_mac, source.id, original_uid)
    register_mac!(actor, device.uid, original_mac)
    register_mac!(actor, device.uid, drifted_mac)
    register_identifier!(actor, device.uid, :integration_id, unique("integration"))
    register_identifier!(actor, device.uid, :integration_id, unique("integration"))

    report =
      ArmisUnmerge.run(
        :execute,
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [device.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
        nil,
        actor
      )

    assert report.split_failures == 0
    assert owner_of_mac(original_mac) == device.uid
    split_uid = owner_of_mac(drifted_mac)
    assert split_uid != device.uid
    assert device_mac(device.uid) == original_mac
    assert device_mac(split_uid) == drifted_mac
  end

  test "live execution requires source and device allowlists and rejects faker sources", %{
    actor: actor
  } do
    source = create_source!(actor, endpoint: "http://serviceradar-faker:8080")
    armis_id = unique("armis-faker")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device = seed_verified_live_candidate!(actor, source.id, armis_id, survivor_mac, split_mac)

    opts =
      [
        armis_unmerge_execute_enabled: true,
        armis_unmerge_include_live: true,
        armis_unmerge_live_device_uids: [device.uid],
        armis_unmerge_live_source_ids: [source.id]
      ]

    dry = ArmisUnmerge.run(:dry_run, opts, nil, actor)
    faker_plan = Enum.find(dry.detected_split_plan, &(&1.device_uid == device.uid))
    assert faker_plan.execution_exclusion_reason == "faker_source_forbidden"

    report =
      ArmisUnmerge.run(
        :execute,
        opts,
        nil,
        actor
      )

    refute report.execution_blocked
    assert report.applied_splits == 0
    assert owner_of_mac(split_mac) == device.uid
  end

  test "an audit failure rolls back device creation and every identifier mutation", %{
    actor: actor
  } do
    source = create_source!(actor)
    armis_id = unique("armis-rollback")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device = seed_verified_live_candidate!(actor, source.id, armis_id, survivor_mac, split_mac)

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    {trigger_name, function_name} = install_audit_failure_trigger!(armis_id)

    on_exit(fn -> remove_audit_failure_trigger!(trigger_name, function_name) end)

    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "armis_unmerge_rollback_#{System.unique_integer([:positive])}.ndjson"
      )

    manifest = Manifest.open(manifest_path, %{test: "rollback"})

    on_exit(fn ->
      Manifest.close(manifest)
      File.rm(manifest_path)
    end)

    report =
      ArmisUnmerge.run(
        :execute,
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [device.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
        manifest,
        actor
      )

    Manifest.close(manifest)

    assert report.split_failures >= 1
    assert owner_of_mac(survivor_mac) == device.uid
    assert owner_of_mac(split_mac) == device.uid
    refute device_exists?(split_uid)
    assert unmerge_audit_count(device.uid) == 0

    manifest_lines = manifest_path |> File.read!() |> String.split("\n", trim: true)
    assert length(manifest_lines) == 1
    refute Enum.any?(manifest_lines, &(&1 =~ "reassign_identifier"))
  end

  # -- seeding helpers -------------------------------------------------------

  defp seed_armis_device!(actor, armis_id, mac, source_id \\ nil, uid \\ nil) do
    metadata =
      maybe_put(
        %{
          "integration_type" => "armis",
          "armis_device_id" => armis_id,
          "integration_id" => armis_id
        },
        "sync_service_id",
        source_id && to_string(source_id)
      )

    device =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: uid || "sr:" <> Ecto.UUID.generate(),
          hostname: unique("unmerge-host"),
          mac: mac,
          discovery_sources: ["armis"],
          metadata: metadata
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
    register_identifier!(actor, device_uid, :mac, mac)
  end

  defp register_identifier!(actor, device_uid, type, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp seed_verified_live_candidate!(actor, source_id, armis_id, survivor_mac, split_mac) do
    device = seed_armis_device!(actor, armis_id, survivor_mac, source_id)
    register_mac!(actor, device.uid, survivor_mac)
    register_mac!(actor, device.uid, split_mac)
    register_identifier!(actor, device.uid, :integration_id, unique("integration"))
    register_identifier!(actor, device.uid, :integration_id, unique("integration"))
    device
  end

  defp create_source!(actor, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: unique("armis-unmerge-source"),
          source_type: :armis,
          endpoint: "https://armis.example.invalid/#{System.unique_integer([:positive])}"
        },
        Map.new(overrides)
      )

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
    |> Ash.Changeset.for_create(
      :create,
      attrs,
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
        "SELECT count(*) FROM platform.merge_audit WHERE to_device_id = $1 AND reason = 'unmerge'",
        [from_uid]
      )

    count
  end

  defp device_exists?(uid) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS(SELECT 1 FROM platform.ocsf_devices WHERE uid = $1)", [uid])

    exists
  end

  defp device_mac(uid) do
    %{rows: [[mac]]} =
      Repo.query!("SELECT mac FROM platform.ocsf_devices WHERE uid = $1", [uid])

    mac
  end

  defp install_audit_failure_trigger!(armis_id) do
    suffix = System.unique_integer([:positive])
    function_name = "fail_armis_unmerge_audit_#{suffix}"
    trigger_name = "fail_armis_unmerge_audit_trigger_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION platform.#{function_name}() RETURNS trigger AS $$
    BEGIN
      IF NEW.reason = 'unmerge' AND NEW.details->>'armis_device_id' = #{sql_literal(armis_id)} THEN
        RAISE EXCEPTION 'forced armis-unmerge audit failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON platform.merge_audit
    FOR EACH ROW EXECUTE FUNCTION platform.#{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp remove_audit_failure_trigger!(trigger_name, function_name) do
    Repo.query!("DROP TRIGGER IF EXISTS #{trigger_name} ON platform.merge_audit")
    Repo.query!("DROP FUNCTION IF EXISTS platform.#{function_name}()")
  end

  defp sql_literal(value), do: "'#{String.replace(value, "'", "''")}'"

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
