defmodule ServiceRadar.Inventory.Remediation.ArmisUnmergeTest do
  @moduledoc """
  DB-backed coverage for the `armis-unmerge` disposition step (OpenSpec
  `remediate-armis-overmerge-disposition`): dry-run plans without writing,
  execute splits a live mega-device per distinct universal MAC (survivor keeps
  the `armis_device_id`), restores a ghost tombstone and rescues its sole-copy
  MAC (TTL reset), writes `unmerge` audits + a rollback manifest, and re-runs
  idempotently.

  Most tests run in a rollback-only database sandbox. The six tests that need
  independent database connections are explicitly unboxed and clean every row
  they commit.
  """

  use ServiceRadar.DataCase, async: false

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

  defmodule FailCommittedWriter do
    @moduledoc false

    alias ServiceRadar.Inventory.Remediation.Manifest.FileWriter

    def sync(device), do: FileWriter.sync(device)

    def write(_device, %{action: "candidate_committed"}),
      do: {:error, {:manifest_sync_failed, :injected_committed_marker_failure}}

    def write(device, entry), do: FileWriter.write(device, entry)
    def write_batch(device, entries), do: FileWriter.write_batch(device, entries)
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup context do
    config_key = DireRemediation
    previous_config = Application.get_env(:serviceradar_core, config_key, [])
    agent_uid = unique("armis-unmerge-agent")

    Application.put_env(
      :serviceradar_core,
      config_key,
      Keyword.put(previous_config, :enable_armis_unmerge_execute, true)
    )

    on_exit(fn -> Application.put_env(:serviceradar_core, config_key, previous_config) end)

    if context[:sandbox] == :unboxed do
      on_exit(fn -> cleanup_unboxed_agent!(agent_uid) end)
    end

    seed_connected_agent!(agent_uid)

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
    evidence_metadata = source_identifier_metadata(source.id)

    register_identifier!(
      actor,
      mega.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

    register_identifier!(
      actor,
      mega.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

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
    assert Enum.any?(manifest_lines, &(&1 =~ ~s("phase":"prepared")))
    assert Enum.any?(manifest_lines, &(&1 =~ "candidate_committed"))

    prepared_audit_ids =
      manifest_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["phase"] == "prepared" and &1["action"] == "create_merge_audit"))
      |> Enum.flat_map(& &1["ids"])
      |> MapSet.new()

    assert prepared_audit_ids == MapSet.new(unmerge_audit_ids(mega.uid))

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

  test "MAC-less and local-only armis devices are reported and left untouched", %{actor: actor} do
    armis_id = unique("armis-local-only")
    locals = [local_mac(), local_mac()]

    local_only = seed_armis_device!(actor, armis_id, nil)
    macless_one = seed_armis_device!(actor, unique("armis-macless-one"), nil)
    macless_two = seed_armis_device!(actor, unique("armis-macless-two"), nil)
    Enum.each(locals, &register_mac!(actor, local_only.uid, &1))

    for suffix <- ["one", "two"] do
      positive = seed_armis_device!(actor, unique("armis-positive-#{suffix}"), nil)
      register_mac!(actor, positive.uid, universal_mac())
      register_mac!(actor, positive.uid, universal_mac())
    end

    run = fn sample_limit ->
      assert {:ok, %{reports: %{"armis-unmerge" => report}}} =
               DireRemediation.run(
                 steps: ["armis-unmerge"],
                 mode: :dry_run,
                 armis_unmerge_candidate_limit: 1,
                 armis_unmerge_plan_sample_limit: sample_limit
               )

      report
    end

    report = run.(2)
    rerun = run.(2)

    expected_skips = MapSet.new([local_only.uid, macless_one.uid, macless_two.uid])
    expected_sample = expected_skips |> Enum.sort() |> Enum.take(2)

    assert report.candidate_devices == 1
    assert report.unsplittable_devices == 3
    assert report.skipped["no_universal_mac"] == report.unsplittable_devices

    assert Enum.map(report.skipped_device_sample, & &1.device_uid) == expected_sample
    assert rerun.skipped_device_sample == report.skipped_device_sample
    assert Enum.all?(report.skipped_device_sample, &(&1.reason == "no_universal_mac"))

    assert run.(0).skipped_device_sample == []

    assert Enum.map(run.(1).skipped_device_sample, & &1.device_uid) ==
             Enum.take(expected_sample, 1)

    refute Enum.any?(report.split_plan, &MapSet.member?(expected_skips, &1.device_uid))
    assert Enum.all?(locals, &(owner_of_mac(&1) == local_only.uid))
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

    local_only_macs = [local_mac(), local_mac()]
    local_only = seed_armis_device!(actor, unique("armis-local-only"), nil, source.id)
    Enum.each(local_only_macs, &register_mac!(actor, local_only.uid, &1))

    unscoped_local_macs = [local_mac(), local_mac()]
    unscoped_local = seed_armis_device!(actor, unique("armis-unscoped-local"), nil, source.id)
    Enum.each(unscoped_local_macs, &register_mac!(actor, unscoped_local.uid, &1))

    opts = [
      armis_unmerge_execute_enabled: true,
      armis_unmerge_include_live: true,
      armis_unmerge_live_device_uids: [allowed.uid, local_only.uid],
      armis_unmerge_live_source_ids: [source.id],
      armis_unmerge_candidate_limit: 1
    ]

    dry = ArmisUnmerge.run(:dry_run, opts, nil, actor)
    assert Enum.map(dry.execution_split_plan, & &1.device_uid) == [allowed.uid]
    assert dry.unsplittable_devices == 1

    assert dry.skipped_device_sample == [
             %{device_uid: local_only.uid, reason: "no_universal_mac"}
           ]

    report = run_execute_with_manifest(opts, actor)

    assert report.applied_splits == 1
    assert owner_of_mac(allowed_split_mac) != allowed.uid
    assert owner_of_mac(excluded_extra_mac) == excluded.uid
    assert Enum.all?(local_only_macs, &(owner_of_mac(&1) == local_only.uid))
    assert Enum.all?(unscoped_local_macs, &(owner_of_mac(&1) == unscoped_local.uid))
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
      run_execute_with_manifest(
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [device.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
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
    evidence_metadata = source_identifier_metadata(source.id)

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

    report =
      run_execute_with_manifest(
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [device.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
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

  test "live source partition must match the universal MAC partition", %{actor: actor} do
    source = create_source!(actor, partition: "tenant-b")
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-source-partition-mismatch"),
        universal_mac(),
        split_mac
      )

    opts = execute_opts(device, source)
    dry_run = ArmisUnmerge.run(:dry_run, opts, nil, actor)

    assert dry_run.skipped["source_partition_mismatch"] >= 1
    assert dry_run.detected_planned_splits == 0

    report = run_execute_with_manifest(opts, actor)

    assert report.applied_splits == 0
    assert report.split_failures == 0
    assert owner_of_mac(split_mac) == device.uid
  end

  test "matching non-default source and MAC partitions execute with the planned UID", %{
    actor: actor
  } do
    partition = "tenant-b"
    source = create_source!(actor, partition: partition)
    armis_id = unique("armis-nondefault-partition")
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        universal_mac(),
        split_mac
      )

    Repo.query!(
      "UPDATE platform.device_identifiers SET partition = $2 WHERE device_id = $1",
      [device.uid, partition]
    )

    expected_split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: partition
      })

    dry_run = ArmisUnmerge.run(:dry_run, execute_opts(device, source), nil, actor)
    assert dry_run.detected_planned_splits == 1

    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.applied_splits == 1
    assert report.split_failures == 0
    assert owner_of_mac(split_mac) == expected_split_uid
    assert device_exists?(expected_split_uid)
  end

  test "metadata-only and ambiguous typed Armis identities never execute", %{actor: actor} do
    source = create_source!(actor)

    metadata_only =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-metadata-only"),
        universal_mac(),
        universal_mac()
      )

    Repo.query!(
      "DELETE FROM platform.device_identifiers " <>
        "WHERE device_id = $1 AND identifier_type = 'armis_device_id'",
      [metadata_only.uid]
    )

    ambiguous_split_mac = universal_mac()

    ambiguous =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-ambiguous"),
        universal_mac(),
        ambiguous_split_mac
      )

    register_identifier!(actor, ambiguous.uid, :armis_device_id, unique("armis-conflict"))

    report =
      ArmisUnmerge.run(
        :dry_run,
        [
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids: [metadata_only.uid, ambiguous.uid],
          armis_unmerge_live_source_ids: [source.id]
        ],
        nil,
        actor
      )

    assert report.skipped["ambiguous_typed_armis_identity"] >= 2
    refute Enum.any?(report.split_plan, &(&1.device_uid in [metadata_only.uid, ambiguous.uid]))
    assert owner_of_mac(ambiguous_split_mac) == ambiguous.uid
  end

  test "lowercase source MAC rows fail the canonical blob-purge precondition", %{actor: actor} do
    source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-lowercase-mac"),
        universal_mac(),
        split_mac
      )

    lowercase_mac = "00aa" <> String.slice(universal_mac(), 4, 8)
    insert_raw_mac!(device.uid, lowercase_mac)

    report = ArmisUnmerge.run(:execute, execute_opts(device, source), nil, actor)

    assert report.execution_blocked
    assert report.execution_blocked_reason == "blob_purge_precondition_failed"
    assert report.preconditions.invalid_mac_rows >= 1
    assert owner_of_mac(split_mac) == device.uid
  end

  test "nil, blank, and mixed MAC partitions are reported and never split", %{actor: actor} do
    source = create_source!(actor)

    candidates =
      for {label, partition} <- [{"nil", nil}, {"blank", "   "}, {"mixed", "tenant-b"}] do
        split_mac = universal_mac()

        device =
          seed_verified_live_candidate!(
            actor,
            source.id,
            unique("armis-partition-#{label}"),
            universal_mac(),
            split_mac
          )

        Repo.query!(
          "UPDATE platform.device_identifiers SET partition = $3 " <>
            "WHERE device_id = $1 AND identifier_type = 'mac' AND identifier_value = $2",
          [device.uid, split_mac, partition]
        )

        {device, split_mac}
      end

    report =
      run_execute_with_manifest(
        [
          armis_unmerge_execute_enabled: true,
          armis_unmerge_include_live: true,
          armis_unmerge_live_device_uids:
            Enum.map(candidates, fn {device, _mac} -> device.uid end),
          armis_unmerge_live_source_ids: [source.id]
        ],
        actor
      )

    assert report.skipped["missing_partition"] >= 2
    assert report.skipped["multiple_partitions"] >= 1

    candidate_uids = MapSet.new(candidates, fn {device, _mac} -> device.uid end)
    refute Enum.any?(report.execution_split_plan, &MapSet.member?(candidate_uids, &1.device_uid))

    for {device, split_mac} <- candidates do
      assert owner_of_mac(split_mac) == device.uid
    end
  end

  test "a display MAC matching multiple planned classes is reported and never split", %{
    actor: actor
  } do
    source = create_source!(actor)
    survivor_mac = universal_mac()
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-ambiguous-display"),
        survivor_mac,
        split_mac
      )

    Repo.query!("UPDATE platform.ocsf_devices SET mac = $2 WHERE uid = $1", [
      device.uid,
      "#{split_mac},#{survivor_mac}"
    ])

    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.skipped["ambiguous_display_mac"] >= 1
    refute Enum.any?(report.execution_split_plan, &(&1.device_uid == device.uid))
    assert owner_of_mac(survivor_mac) == device.uid
    assert owner_of_mac(split_mac) == device.uid
  end

  test "live evidence must be linked to the canonical Armis source", %{actor: actor} do
    source = create_source!(actor)
    other_source = create_source!(actor)
    survivor_mac = universal_mac()
    split_mac = universal_mac()

    device =
      seed_armis_device!(
        actor,
        unique("armis-unproven-evidence"),
        survivor_mac,
        source.id
      )

    register_mac!(actor, device.uid, survivor_mac)
    register_mac!(actor, device.uid, split_mac)

    unrelated_metadata = %{
      "sync_service_id" => to_string(other_source.id),
      "integration_type" => "proxmox"
    }

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      unrelated_metadata
    )

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      unrelated_metadata
    )

    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.skipped["missing_live_overmerge_signal"] >= 1
    assert report.applied_splits == 0
    refute Enum.any?(report.split_plan, &(&1.device_uid == device.uid))
    assert owner_of_mac(split_mac) == device.uid
  end

  test "typed Armis identity provenance must match the canonical source", %{actor: actor} do
    source = create_source!(actor)
    other_source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-unproven-typed"),
        universal_mac(),
        split_mac
      )

    Repo.query!(
      "UPDATE platform.device_identifiers SET metadata = $2::jsonb " <>
        "WHERE device_id = $1 AND identifier_type = 'armis_device_id'",
      [device.uid, Jason.encode!(source_identifier_metadata(other_source.id))]
    )

    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.skipped["unproven_armis_identity_source"] >= 1
    assert report.applied_splits == 0
    refute Enum.any?(report.split_plan, &(&1.device_uid == device.uid))
    assert owner_of_mac(split_mac) == device.uid
  end

  test "a foreign display-only MAC owner blocks the complete candidate", %{actor: actor} do
    source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-display-owner"),
        universal_mac(),
        split_mac
      )

    _foreign = create_device!(actor, formatted_lowercase_mac(split_mac))
    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.applied_splits == 0
    assert report.split_failures == 1
    assert owner_of_mac(split_mac) == device.uid
  end

  test "a foreign normalized legacy MAC identifier owner blocks the candidate", %{actor: actor} do
    source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-legacy-owner"),
        universal_mac(),
        split_mac
      )

    foreign = create_device!(actor, nil)
    insert_raw_mac!(foreign.uid, "#{String.downcase(split_mac)};#{universal_mac()}")

    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.applied_splits == 0
    assert report.split_failures == 1
    assert owner_of_mac(split_mac) == device.uid
  end

  @tag sandbox: :unboxed
  test "the owner barrier serializes a concurrent foreign identifier insert", %{actor: actor} do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-concurrent-owner")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device_uid = test_device_uid()
    foreign_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, foreign_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        survivor_mac,
        split_mac,
        device_uid
      )

    foreign = create_device!(actor, nil, foreign_uid)

    manifest_path = temporary_manifest_path("concurrent_owner")
    manifest = Manifest.open(manifest_path, %{test: "concurrent_owner"})

    writer =
      hold_raw_mac_insert_async(
        foreign.uid,
        formatted_lowercase_mac(split_mac),
        unique("other-partition")
      )

    writer_pid = writer.pid

    try do
      assert_receive {:identifier_insert_held, ^writer_pid}, 5_000

      runner =
        Task.async(fn ->
          ArmisUnmerge.run(:execute, execute_opts(device, source), manifest, actor)
        end)

      try do
        assert wait_for_manifest_entry(manifest_path, "candidate_preflight")
        assert wait_for_pending_owner_barrier()
        send(writer.pid, :commit)
        assert {:ok, :committed} = Task.await(writer, 5_000)

        report = Task.await(runner, 15_000)

        assert report.applied_splits == 0
        assert report.split_failures == 1
        assert owner_of_mac(split_mac) == device.uid
        refute device_exists?(split_uid)
      after
        release_and_await_task(writer)
        await_task_termination(runner, 15_000)
      end
    after
      release_and_await_task(writer)
      Manifest.close(manifest)
      File.rm(manifest_path)
      cleanup_unboxed!([source.id], [device.uid, foreign.uid, split_uid])
    end
  end

  @tag sandbox: :unboxed
  test "owner-barrier lock timeout returns a structured failure and manifest path", %{
    actor: actor
  } do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    split_mac = universal_mac()
    device_uid = test_device_uid()
    register_unboxed_cleanup!([], [device_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-lock-timeout"),
        universal_mac(),
        split_mac,
        device_uid
      )

    locker = hold_owner_table_lock_async()
    manifest_path = temporary_manifest_path("lock_timeout")

    try do
      assert_receive {:owner_table_lock_held, locker_pid}, 5_000
      assert locker_pid == locker.pid

      assert {:error, {:step_failures, result}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["armis-unmerge"],
                 manifest_path: manifest_path,
                 actor: actor,
                 armis_unmerge_include_live: true,
                 armis_unmerge_live_device_uids: [device.uid],
                 armis_unmerge_live_source_ids: [source.id]
               )

      report = result.reports["armis-unmerge"]
      assert result.manifest_path == Path.expand(manifest_path)
      assert result.failures["armis-unmerge"].split_failures == 1
      assert report.applied_splits == 0
      assert report.split_failures == 1
      assert owner_of_mac(split_mac) == device.uid

      manifest_lines = manifest_path |> File.read!() |> String.split("\n", trim: true)
      assert Enum.any?(manifest_lines, &(&1 =~ "candidate_preflight"))
      refute Enum.any?(manifest_lines, &(&1 =~ ~s("phase":"prepared")))
      refute Enum.any?(manifest_lines, &(&1 =~ "candidate_committed"))

      send(locker.pid, :commit)
      assert {:ok, :committed} = Task.await(locker, 5_000)
    after
      release_and_await_task(locker)
      File.rm(manifest_path)
      cleanup_unboxed!([source.id], [device.uid])
    end
  end

  test "an existing deterministic split target is never adopted or overwritten", %{actor: actor} do
    source = create_source!(actor)
    armis_id = unique("armis-existing-target")
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        universal_mac(),
        split_mac
      )

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    target = create_device!(actor, nil, split_uid)
    report = run_execute_with_manifest(execute_opts(device, source), actor)

    assert report.applied_splits == 0
    assert report.split_failures == 1
    assert owner_of_mac(split_mac) == device.uid
    assert device_mac(target.uid) == nil
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
    assert length(manifest_lines) == 2
    assert Enum.any?(manifest_lines, &(&1 =~ "candidate_preflight"))
    refute Enum.any?(manifest_lines, &(&1 =~ "reassign_identifier"))
    refute Enum.any?(manifest_lines, &(&1 =~ "candidate_committed"))
  end

  test "execute requires a writable manifest before the first mutation", %{actor: actor} do
    source = create_source!(actor)
    split_mac = universal_mac()

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        unique("armis-manifest-required"),
        universal_mac(),
        split_mac
      )

    report =
      ArmisUnmerge.run(
        :execute,
        execute_opts(device, source),
        nil,
        actor
      )

    assert report.applied_splits == 0
    assert report.split_failures == 1
    assert report.manifest_failures == 1
    assert owner_of_mac(split_mac) == device.uid
  end

  @tag sandbox: :unboxed
  test "source state drift after planning rejects the candidate before mutation", %{actor: actor} do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-stale-plan")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    drifted_mac = universal_mac()
    device_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        survivor_mac,
        split_mac,
        device_uid
      )

    manifest_path = temporary_manifest_path("stale_plan")
    manifest = Manifest.open(manifest_path, %{test: "stale_plan"})
    writer = hold_source_device_update_async(device.uid, drifted_mac)
    writer_pid = writer.pid

    try do
      assert_receive {:source_update_held, ^writer_pid}, 5_000

      runner =
        Task.async(fn ->
          ArmisUnmerge.run(:execute, execute_opts(device, source), manifest, actor)
        end)

      try do
        assert wait_for_manifest_entry(manifest_path, "candidate_preflight")
        send(writer.pid, :commit)
        assert {:ok, :committed} = Task.await(writer, 5_000)

        report = Task.await(runner, 15_000)

        assert report.applied_splits == 0
        assert report.split_failures == 1
        assert owner_of_mac(split_mac) == device.uid
        assert device_mac(device.uid) == drifted_mac
        refute device_exists?(split_uid)
      after
        release_and_await_task(writer)
        await_task_termination(runner, 15_000)
      end
    after
      release_and_await_task(writer)
      Manifest.close(manifest)
      File.rm(manifest_path)
      cleanup_unboxed!([source.id], [device.uid, split_uid])
    end
  end

  @tag sandbox: :unboxed
  test "integration source partition drift after planning rejects before mutation", %{
    actor: actor
  } do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-source-partition-drift")
    split_mac = universal_mac()
    device_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        universal_mac(),
        split_mac,
        device_uid
      )

    manifest_path = temporary_manifest_path("source_partition_drift")
    manifest = Manifest.open(manifest_path, %{test: "source_partition_drift"})
    writer = hold_integration_source_partition_update_async(source.id, "tenant-b")
    writer_pid = writer.pid

    try do
      assert_receive {:source_partition_update_held, ^writer_pid}, 5_000

      runner =
        Task.async(fn ->
          ArmisUnmerge.run(:execute, execute_opts(device, source), manifest, actor)
        end)

      try do
        assert wait_for_manifest_entry(manifest_path, "candidate_preflight")
        send(writer.pid, :commit)
        assert {:ok, :committed} = Task.await(writer, 5_000)

        report = Task.await(runner, 15_000)

        assert report.applied_splits == 0
        assert report.split_failures == 1
        assert owner_of_mac(split_mac) == device.uid
        refute device_exists?(split_uid)
      after
        release_and_await_task(writer)
        await_task_termination(runner, 15_000)
      end
    after
      release_and_await_task(writer)
      Manifest.close(manifest)
      File.rm(manifest_path)
      cleanup_unboxed!([source.id], [device.uid, split_uid])
    end
  end

  @tag sandbox: :unboxed
  test "source identifier drift after planning rejects the candidate before mutation", %{
    actor: actor
  } do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-identifier-drift")
    split_mac = universal_mac()
    device_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        universal_mac(),
        split_mac,
        device_uid
      )

    writer = hold_source_identifier_insert_async(device.uid, unique("agent-drift"))
    writer_pid = writer.pid

    try do
      assert_receive {:source_identifier_insert_held, ^writer_pid}, 5_000

      report = run_concurrent_execute(device, source, writer)

      assert report.applied_splits == 0
      assert report.split_failures == 1
      assert owner_of_mac(split_mac) == device.uid
      refute device_exists?(split_uid)
    after
      release_and_await_task(writer)
      cleanup_unboxed!([source.id], [device.uid, split_uid])
    end
  end

  @tag sandbox: :unboxed
  test "last_seen-only churn remains outside the ownership snapshot", %{actor: actor} do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-timestamp-churn")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        survivor_mac,
        split_mac,
        device_uid
      )

    writer = hold_identifier_timestamp_update_async(device.uid, split_mac)
    writer_pid = writer.pid

    try do
      assert_receive {:identifier_timestamp_update_held, ^writer_pid}, 5_000

      report = run_concurrent_execute(device, source, writer)

      assert report.applied_splits == 1
      assert report.split_failures == 0
      assert owner_of_mac(split_mac) == split_uid
    after
      release_and_await_task(writer)
      cleanup_unboxed!([source.id], [device.uid, split_uid])
    end
  end

  @tag sandbox: :unboxed
  test "prepared-manifest failure rolls back the candidate and halts execution", %{actor: actor} do
    source = create_source!(actor)
    register_unboxed_cleanup!([source.id], [])

    armis_id = unique("armis-manifest-prepare")
    survivor_mac = universal_mac()
    split_mac = universal_mac()
    device_uid = test_device_uid()

    split_uid =
      Ids.generate_deterministic_device_id(%{
        armis_id: armis_id,
        mac: split_mac,
        partition: "default"
      })

    register_unboxed_cleanup!([], [device_uid, split_uid])

    device =
      seed_verified_live_candidate!(
        actor,
        source.id,
        armis_id,
        survivor_mac,
        split_mac,
        device_uid
      )

    manifest_path = temporary_manifest_path("prepare_failure")
    manifest = Manifest.open(manifest_path, %{test: "prepare_failure"})
    writer = hold_source_device_update_async(device.uid, nil)
    writer_pid = writer.pid

    try do
      assert_receive {:source_update_held, ^writer_pid}, 5_000

      runner =
        Task.async(fn ->
          ArmisUnmerge.run(:execute, execute_opts(device, source), manifest, actor)
        end)

      try do
        assert wait_for_manifest_entry(manifest_path, "candidate_preflight")
        Manifest.close(manifest)
        send(writer.pid, :commit)
        assert {:ok, :committed} = Task.await(writer, 5_000)

        report = Task.await(runner, 15_000)

        assert report.applied_splits == 0
        assert report.split_failures == 1
        assert report.manifest_failures == 1
        assert owner_of_mac(survivor_mac) == device.uid
        assert owner_of_mac(split_mac) == device.uid
        refute device_exists?(split_uid)
        assert unmerge_audit_count(device.uid) == 0
      after
        release_and_await_task(writer)
        await_task_termination(runner, 15_000)
      end
    after
      release_and_await_task(writer)
      Manifest.close(manifest)
      File.rm(manifest_path)
      cleanup_unboxed!([source.id], [device.uid, split_uid])
    end
  end

  test "committed-marker failure preserves committed mutations and reports failure", %{
    actor: actor
  } do
    source = create_source!(actor)
    armis_id = unique("armis-manifest-committed")
    split_mac = universal_mac()
    device = seed_verified_live_candidate!(actor, source.id, armis_id, universal_mac(), split_mac)
    manifest_path = temporary_manifest_path("committed_failure")
    manifest = Manifest.open(manifest_path, %{test: "committed_failure"})
    faulting_manifest = %{manifest | writer: FailCommittedWriter}

    on_exit(fn ->
      Manifest.close(manifest)
      File.rm(manifest_path)
    end)

    report = ArmisUnmerge.run(:execute, execute_opts(device, source), faulting_manifest, actor)
    Manifest.close(manifest)

    assert report.applied_splits == 1
    assert report.split_failures == 1
    assert report.manifest_failures == 1
    assert owner_of_mac(split_mac) != device.uid
    assert unmerge_audit_count(device.uid) == 1

    manifest_lines = manifest_path |> File.read!() |> String.split("\n", trim: true)
    assert Enum.any?(manifest_lines, &(&1 =~ ~s("phase":"prepared")))
    refute Enum.any?(manifest_lines, &(&1 =~ "candidate_committed"))
  end

  # -- seeding helpers -------------------------------------------------------

  defp seed_connected_agent!(agent_uid) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_agents
        (uid, name, status, is_healthy, first_seen_time, last_seen_time, created_time)
      VALUES
        ($1, $1, 'connected', true, timezone('utc', now()),
         timezone('utc', now()), timezone('utc', now()))
      """,
      [agent_uid]
    )
  end

  defp cleanup_unboxed_agent!(agent_uid) do
    Repo.query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [agent_uid])
  end

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

    identifier_metadata = if source_id, do: source_identifier_metadata(source_id), else: %{}

    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device.uid,
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default",
        confidence: :strong,
        metadata: identifier_metadata
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    device
  end

  defp register_mac!(actor, device_uid, mac) do
    register_identifier!(actor, device_uid, :mac, mac)
  end

  defp register_identifier!(actor, device_uid, type, value, metadata \\ %{}) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        metadata: metadata
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp insert_raw_mac!(device_uid, value) do
    Repo.query!(
      """
      INSERT INTO platform.device_identifiers
        (device_id, identifier_type, identifier_value, partition, confidence,
         first_seen, last_seen, metadata)
      VALUES ($1, 'mac', $2, 'default', 'strong',
              timezone('utc', now()), timezone('utc', now()), '{}'::jsonb)
      """,
      [device_uid, value]
    )
  end

  defp create_device!(actor, mac, uid \\ nil) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{uid: uid || "sr:" <> Ecto.UUID.generate(), hostname: unique("owner"), mac: mac},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp seed_verified_live_candidate!(
         actor,
         source_id,
         armis_id,
         survivor_mac,
         split_mac,
         uid \\ nil
       ) do
    device = seed_armis_device!(actor, armis_id, survivor_mac, source_id, uid)
    register_mac!(actor, device.uid, survivor_mac)
    register_mac!(actor, device.uid, split_mac)
    evidence_metadata = source_identifier_metadata(source_id)

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

    register_identifier!(
      actor,
      device.uid,
      :integration_id,
      unique("integration"),
      evidence_metadata
    )

    device
  end

  defp source_identifier_metadata(source_id) do
    %{"sync_service_id" => to_string(source_id), "integration_type" => "armis"}
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

  defp execute_opts(device, source) do
    [
      armis_unmerge_execute_enabled: true,
      armis_unmerge_include_live: true,
      armis_unmerge_live_device_uids: [device.uid],
      armis_unmerge_live_source_ids: [source.id]
    ]
  end

  defp run_execute_with_manifest(opts, actor) do
    path = temporary_manifest_path("direct")

    manifest = Manifest.open(path, %{test: "direct_execute"})

    try do
      ArmisUnmerge.run(:execute, opts, manifest, actor)
    after
      Manifest.close(manifest)
      File.rm(path)
    end
  end

  defp temporary_manifest_path(label) do
    Path.join(
      System.tmp_dir!(),
      "armis_unmerge_#{label}_#{System.unique_integer([:positive])}.ndjson"
    )
  end

  defp hold_source_device_update_async(uid, mac) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        if mac do
          Repo.query!("UPDATE platform.ocsf_devices SET mac = $2 WHERE uid = $1", [uid, mac])
        else
          Repo.query!("UPDATE platform.ocsf_devices SET mac = mac WHERE uid = $1", [uid])
        end

        send(parent, {:source_update_held, self()})

        receive do
          :commit -> :ok
        after
          10_000 ->
            raise "timed out waiting to commit source-device update"
        end

        :committed
      end)
    end)
  end

  defp hold_integration_source_partition_update_async(source_id, partition) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE platform.integration_sources SET partition = $2 WHERE id::text = $1",
          [source_id, partition]
        )

        send(parent, {:source_partition_update_held, self()})

        receive do
          :commit -> :ok
        after
          10_000 -> raise "timed out waiting to commit integration-source partition update"
        end

        :committed
      end)
    end)
  end

  defp hold_owner_table_lock_async do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE platform.device_identifiers IN ROW EXCLUSIVE MODE")
        send(parent, {:owner_table_lock_held, self()})

        receive do
          :commit -> :ok
        after
          15_000 -> raise "timed out waiting to release owner-table lock"
        end

        :committed
      end)
    end)
  end

  defp hold_raw_mac_insert_async(device_uid, value, partition) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO platform.device_identifiers
            (device_id, identifier_type, identifier_value, partition, confidence,
             first_seen, last_seen, metadata)
          VALUES ($1, 'mac', $2, $3, 'strong',
                  timezone('utc', now()), timezone('utc', now()), '{}'::jsonb)
          """,
          [device_uid, value, partition]
        )

        send(parent, {:identifier_insert_held, self()})

        receive do
          :commit -> :ok
        after
          10_000 -> raise "timed out waiting to commit identifier insert"
        end

        :committed
      end)
    end)
  end

  defp hold_source_identifier_insert_async(device_uid, value) do
    hold_identifier_write_async(
      """
      INSERT INTO platform.device_identifiers
        (device_id, identifier_type, identifier_value, partition, confidence,
         first_seen, last_seen, metadata)
      VALUES ($1, 'agent_id', $2, 'default', 'strong',
              timezone('utc', now()), timezone('utc', now()), '{}'::jsonb)
      """,
      [device_uid, value],
      :source_identifier_insert_held
    )
  end

  defp hold_identifier_timestamp_update_async(device_uid, mac) do
    hold_identifier_write_async(
      """
      UPDATE platform.device_identifiers
      SET last_seen = timezone('utc', now()) + interval '1 second'
      WHERE device_id = $1 AND identifier_type = 'mac' AND identifier_value = $2
      """,
      [device_uid, mac],
      :identifier_timestamp_update_held
    )
  end

  defp hold_identifier_write_async(sql, params, signal) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!(sql, params)
        send(parent, {signal, self()})

        receive do
          :commit -> :ok
        after
          10_000 -> raise "timed out waiting to commit identifier write"
        end

        :committed
      end)
    end)
  end

  defp run_concurrent_execute(device, source, writer) do
    manifest_path = temporary_manifest_path("concurrent_source")
    manifest = Manifest.open(manifest_path, %{test: "concurrent_source"})

    runner =
      Task.async(fn ->
        ArmisUnmerge.run(
          :execute,
          execute_opts(device, source),
          manifest,
          SystemActor.system(:concurrent_execute)
        )
      end)

    try do
      assert wait_for_manifest_entry(manifest_path, "candidate_preflight")
      assert wait_for_pending_owner_barrier()
      send(writer.pid, :commit)
      assert {:ok, :committed} = Task.await(writer, 5_000)
      Task.await(runner, 15_000)
    after
      release_and_await_task(writer)
      await_task_termination(runner, 15_000)
      Manifest.close(manifest)
      File.rm(manifest_path)
    end
  end

  defp release_and_await_task(task, timeout \\ 5_000) do
    if Process.alive?(task.pid) do
      send(task.pid, :commit)
      await_task_termination(task, timeout)
    end

    :ok
  end

  defp await_task_termination(task, timeout) do
    if Process.alive?(task.pid) do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, _result} -> :ok
        {:exit, _reason} -> :ok
        nil -> :ok
      end
    end

    :ok
  end

  defp register_unboxed_cleanup!(source_ids, device_uids) do
    on_exit(fn -> cleanup_unboxed!(source_ids, device_uids) end)
  end

  defp cleanup_unboxed!(source_ids, device_uids) do
    device_uids = Enum.uniq(device_uids)

    Repo.query!(
      "DELETE FROM platform.merge_audit " <>
        "WHERE from_device_id = ANY($1::text[]) OR to_device_id = ANY($1::text[])",
      [device_uids]
    )

    Repo.query!(
      "DELETE FROM platform.device_identifiers WHERE device_id = ANY($1::text[])",
      [device_uids]
    )

    Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = ANY($1::text[])", [device_uids])

    Repo.query!(
      "DELETE FROM platform.integration_sources WHERE id::text = ANY($1::text[])",
      [Enum.map(source_ids, &to_string/1)]
    )

    :ok
  end

  defp wait_for_manifest_entry(path, marker, attempts \\ 200)

  defp wait_for_manifest_entry(_path, _marker, 0), do: false

  defp wait_for_manifest_entry(path, marker, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        if String.contains?(contents, marker) do
          true
        else
          Process.sleep(25)
          wait_for_manifest_entry(path, marker, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(25)
        wait_for_manifest_entry(path, marker, attempts - 1)
    end
  end

  defp wait_for_pending_owner_barrier(attempts \\ 200)

  defp wait_for_pending_owner_barrier(0), do: false

  defp wait_for_pending_owner_barrier(attempts) do
    %{rows: [[waiting]]} =
      Repo.query!("""
      SELECT EXISTS (
        SELECT 1
        FROM pg_locks
        WHERE relation = 'platform.device_identifiers'::regclass
          AND mode = 'ShareRowExclusiveLock'
          AND NOT granted
      )
      """)

    if waiting do
      true
    else
      Process.sleep(25)
      wait_for_pending_owner_barrier(attempts - 1)
    end
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

  defp unmerge_audit_ids(from_uid) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_id::text FROM platform.merge_audit " <>
          "WHERE to_device_id = $1 AND reason = 'unmerge' ORDER BY event_id",
        [from_uid]
      )

    Enum.map(rows, fn [event_id] -> event_id end)
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

  defp formatted_lowercase_mac(mac) do
    mac
    |> String.downcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp test_device_uid, do: "sr:" <> Ecto.UUID.generate()
end
