defmodule ServiceRadar.Inventory.Remediation.DireRemediationTest do
  @moduledoc """
  DB-backed coverage for `mix serviceradar.dire_remediation` (DIRE tasks
  4.1-4.4): miniature versions of each live pathology are seeded, the
  dry-run is asserted to count them without mutating, and execute mode is
  asserted to remediate them idempotently.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:dire_remediation_test)}
  end

  # ---------------------------------------------------------------------------
  # blob-purge (4.1)
  # ---------------------------------------------------------------------------

  test "blob-purge: dry run counts the pathology without mutating", %{actor: actor} do
    {:ok, device} = create_device(actor)
    blob_old = "#{unique_mac()},#{unique_mac()}"
    blob_new = "#{unique_mac()},#{unique_mac()}"
    {:ok, old_row} = seed_mac(actor, device.uid, blob_old)
    {:ok, _new_row} = seed_mac(actor, device.uid, blob_new)
    age_identifier(old_row.id, ~U[2026-01-01 00:00:00Z])

    assert {:ok, %{mode: :dry_run, manifest_path: nil, reports: %{"blob-purge" => report}}} =
             DireRemediation.run(steps: ["blob-purge"], actor: actor)

    assert report.deleted_rows == 0
    assert report.extracted_macs == 0
    assert report.invalid_mac_rows >= 2
    assert report.blob_only_devices >= 1
    assert report.would_delete_rows == report.invalid_mac_rows

    values = device |> mac_identifiers(actor) |> Enum.map(& &1.identifier_value)
    assert Enum.sort(values) == Enum.sort([blob_old, blob_new])
  end

  test "blob-purge: execute extracts first MAC of the most recent blob, then purges",
       %{actor: actor} do
    # Pathology 1: device whose ONLY mac identifiers are blobs.
    {:ok, blob_device} = create_device(actor)
    first_of_new = unique_mac()
    blob_old = "#{unique_mac()},#{unique_mac()}"
    blob_new = "#{first_of_new},#{unique_mac()}"
    {:ok, old_row} = seed_mac(actor, blob_device.uid, blob_old)
    {:ok, _} = seed_mac(actor, blob_device.uid, blob_new)
    age_identifier(old_row.id, ~U[2026-01-01 00:00:00Z])

    # Pathology 2: device with a blob AND a valid row — no extraction needed.
    {:ok, mixed_device} = create_device(actor)
    valid_mac = unique_mac()
    {:ok, _} = seed_mac(actor, mixed_device.uid, valid_mac)
    {:ok, _} = seed_mac(actor, mixed_device.uid, "#{unique_mac()},#{unique_mac()}")

    manifest_path = manifest_path("blob")

    assert {:ok, %{mode: :execute, reports: %{"blob-purge" => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["blob-purge"],
               actor: actor,
               manifest_path: manifest_path,
               batch_size: 10
             )

    assert report.deleted_rows >= 3
    assert report.extracted_macs >= 1

    # Blob-only device: exactly one valid extracted identifier remains.
    assert [extracted] = mac_identifiers(blob_device, actor)
    assert extracted.identifier_value == first_of_new
    assert extracted.source == "remediation"
    assert extracted.confidence == IdentityReconciler.mac_confidence(first_of_new)

    # Mixed device: the valid row survives, the blob is gone, nothing extracted.
    assert [survivor] = mac_identifiers(mixed_device, actor)
    assert survivor.identifier_value == valid_mac
    refute survivor.source == "remediation"

    assert_manifest_records(manifest_path, "blob-purge", "delete_invalid_mac_rows")

    # Idempotent: a second run finds nothing to do for these devices.
    assert {:ok, %{reports: %{"blob-purge" => second}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["blob-purge"],
               actor: actor,
               manifest_path: manifest_path("blob2")
             )

    assert second.deleted_rows == 0
    assert [_] = mac_identifiers(blob_device, actor)
  end

  # ---------------------------------------------------------------------------
  # test-debris (4.2)
  # ---------------------------------------------------------------------------

  test "test-debris: dry run lists debris, execute removes it (and only it)",
       %{actor: actor} do
    seed = test_seed()
    debris_uid = "test-agent-#{seed}"
    sim_uid = "agent-active-ip-conflict-#{seed}"
    keeper_uid = "test-agent-keeper-#{seed}"

    {:ok, sim_device} = create_device(actor)
    {:ok, _} = create_agent(actor, debris_uid, %{})
    {:ok, _} = create_agent(actor, sim_uid, %{device_uid: sim_device.uid})
    {:ok, _} = create_agent(actor, keeper_uid, %{})
    make_debris!(debris_uid)
    make_debris!(sim_uid)

    {:ok, reip_device} =
      create_device(actor, %{hostname: "k8s-pod-b", agent_id: "agent-reip-#{seed}"})

    {:ok, _} = seed_mac(actor, reip_device.uid, unique_mac())

    {:ok, _alias_state} =
      seed_alias(actor, reip_device.uid, "10.93.#{:rand.uniform(250)}.#{:rand.uniform(250)}")

    assert {:ok, %{reports: %{"test-debris" => dry}}} =
             DireRemediation.run(steps: ["test-debris"], actor: actor)

    assert debris_uid in dry.debris_agent_uids
    assert sim_uid in dry.debris_agent_uids
    refute keeper_uid in dry.debris_agent_uids
    assert reip_device.uid in dry.debris_device_uids
    assert dry.would_delete_identifiers >= 1
    assert dry.would_delete_alias_states >= 1

    # Dry run mutated nothing.
    assert {:ok, _} = Agent.get_by_uid(debris_uid, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(reip_device.uid, false, actor: actor)

    assert {:ok, %{reports: %{"test-debris" => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["test-debris"],
               actor: actor,
               manifest_path: manifest_path("debris")
             )

    assert report.deleted_agents >= 2
    assert report.soft_deleted_devices >= 1

    assert {:error, _} = Agent.get_by_uid(debris_uid, actor: actor)
    assert {:error, _} = Agent.get_by_uid(sim_uid, actor: actor)
    assert {:ok, _} = Agent.get_by_uid(keeper_uid, actor: actor)

    # reip device tombstoned with its identifiers/aliases gone; the sim
    # agent's (non-debris) device is untouched.
    assert {:ok, %Device{deleted_at: %DateTime{}, deleted_reason: "dire_remediation_test_debris"}} =
             Device.get_by_uid(reip_device.uid, true, actor: actor)

    assert mac_identifiers(reip_device, actor) == []

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(sim_device.uid, false, actor: actor)
  end

  # ---------------------------------------------------------------------------
  # agent-links (4.3)
  # ---------------------------------------------------------------------------

  test "stale-agent-devices: reaps unavailable churn agents without deleting canonical devices",
       %{actor: actor} do
    seed = test_seed()
    stale_exact = "agent-dusk-test-exact-#{seed}"
    stale_prefix = "agent-dusk01-test-#{seed}"
    active_agent = "agent-dusk01-current-#{seed}"
    protected_agent = "agent-protected-current-#{seed}"

    {:ok, canonical} =
      create_device(actor, %{
        hostname: "dusk01-current-#{seed}",
        agent_id: active_agent,
        discovery_sources: ["agent", "sweep"]
      })

    {:ok, stale_owned} =
      create_device(actor, %{
        hostname: "dusk-stale-#{seed}",
        agent_id: stale_prefix,
        discovery_sources: ["sysmon", "agent", "sweep"]
      })

    {:ok, protected_device} =
      create_device(actor, %{
        hostname: "dusk-protected-#{seed}",
        agent_id: stale_exact,
        discovery_sources: ["agent"]
      })

    {:ok, _} = create_agent(actor, active_agent, %{device_uid: canonical.uid})
    {:ok, _} = create_agent(actor, protected_agent, %{device_uid: protected_device.uid})
    {:ok, _} = create_agent(actor, stale_exact, %{device_uid: canonical.uid})
    {:ok, _} = create_agent(actor, stale_prefix, %{device_uid: stale_owned.uid})
    make_stale_agent!(stale_exact)
    make_stale_agent!(stale_prefix)

    {:ok, _} = seed_agent_identifier(actor, stale_exact, canonical.uid)
    {:ok, _} = seed_agent_identifier(actor, stale_prefix, stale_owned.uid)
    {:ok, alias_state} = seed_alias(actor, stale_owned.uid, "10.95.#{:rand.uniform(250)}.1")

    opts = [
      steps: ["stale-agent-devices"],
      actor: actor,
      stale_agent_uids: [stale_exact],
      stale_agent_prefixes: ["agent-dusk01-test-"],
      stale_agent_before: ~U[2026-05-01 00:00:00Z]
    ]

    assert {:ok, %{reports: %{"stale-agent-devices" => dry}}} = DireRemediation.run(opts)

    assert dry.stale_agents == 2
    assert Enum.sort(dry.stale_agent_uids) == Enum.sort([stale_exact, stale_prefix])
    assert dry.stale_device_uids == [stale_owned.uid]
    assert dry.would_delete_identifiers == 2
    assert dry.would_delete_alias_states == 1

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(stale_owned.uid, false, actor: actor)

    manifest_path = manifest_path("stale_agents")

    assert {:ok, %{reports: %{"stale-agent-devices" => report}}} =
             DireRemediation.run([{:mode, :execute}, {:manifest_path, manifest_path} | opts])

    assert report.deleted_agents == 2
    assert report.deleted_identifiers == 2
    assert report.deleted_alias_states == 1
    assert report.soft_deleted_devices == 1

    assert {:error, _} = Agent.get_by_uid(stale_exact, actor: actor)
    assert {:error, _} = Agent.get_by_uid(stale_prefix, actor: actor)
    assert {:ok, _} = Agent.get_by_uid(active_agent, actor: actor)
    assert {:ok, _} = Agent.get_by_uid(protected_agent, actor: actor)

    assert {:ok, %Device{deleted_at: %DateTime{}, deleted_reason: "dire_remediation_stale_agent"}} =
             Device.get_by_uid(stale_owned.uid, true, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(canonical.uid, false, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(protected_device.uid, false, actor: actor)

    assert agent_identifiers(actor, stale_exact) == []
    assert agent_identifiers(actor, stale_prefix) == []

    assert {:error, _} = Ash.get(DeviceAliasState, alias_state.id, actor: actor)

    assert_manifest_records(manifest_path, "stale-agent-devices", "soft_delete_devices")

    assert {:ok, %{reports: %{"stale-agent-devices" => second}}} = DireRemediation.run(opts)
    assert second.stale_agents == 0
    assert second.stale_devices == 0
    assert second.would_delete_identifiers == 0
  end

  test "agent-links: rebuilds per-host devices from ocsf_agents ground truth",
       %{actor: actor} do
    seed = test_seed()
    host_a = "remtest-w1-#{seed}"
    host_b = "remtest-w2-#{seed}"
    host_c = "remtest-w3-#{seed}"
    octet = :rand.uniform(250)
    ip_a = "10.94.#{octet}.1"
    ip_b = "10.94.#{octet}.2"
    ip_c = "10.94.#{octet}.3"
    agent_a = "rem-agent-a-#{seed}"
    agent_b = "rem-agent-b-#{seed}"
    agent_c = "rem-agent-c-#{seed}"

    # The chimera: host A's device; host B's device was merged into it.
    {:ok, chimera} = create_device(actor, %{hostname: host_a, ip: ip_a, agent_id: agent_a})
    {:ok, dev_b} = create_device(actor, %{hostname: host_b, ip: ip_b, agent_id: agent_b})
    {:ok, stale_b} = create_device(actor, %{hostname: "stale-#{host_b}", agent_id: agent_b})
    {:ok, stale_c} = create_device(actor, %{hostname: "stale-#{host_c}", agent_id: agent_c})

    assert :ok =
             IdentityReconciler.merge_devices(dev_b.uid, chimera.uid,
               actor: actor,
               reason: "manual_test_seed"
             )

    # All three connected agents point at the chimera.
    {:ok, _} = create_agent(actor, agent_a, %{host: host_a, ip: ip_a, device_uid: chimera.uid})
    {:ok, _} = create_agent(actor, agent_b, %{host: host_b, ip: ip_b, device_uid: chimera.uid})
    {:ok, _} = create_agent(actor, agent_c, %{host: host_c, ip: ip_c, device_uid: chimera.uid})

    # Stranded agent_id identifier + poisoned alias for host B on the chimera.
    {:ok, _} = seed_agent_identifier(actor, agent_b, chimera.uid)
    {:ok, alias_state} = seed_alias(actor, chimera.uid, ip_b)

    # Corrupted ip literal (scoped to this test via a unique literal).
    literal = "agent-lit-#{seed}"
    {:ok, literal_device} = create_device(actor, %{hostname: "remtest-lit-#{seed}", ip: literal})

    run_opts = [
      steps: ["agent-links"],
      actor: actor,
      agent_uids: [agent_a, agent_b, agent_c],
      ip_literal: literal
    ]

    assert {:ok, %{reports: %{"agent-links" => dry}}} = DireRemediation.run(run_opts)

    plans = Map.new(dry.plans, &{&1.agent_uid, &1})
    assert plans[agent_a].action == :keep
    assert plans[agent_a].target_device_uid == chimera.uid
    assert plans[agent_b].action == :restore
    assert plans[agent_b].target_device_uid == dev_b.uid
    assert plans[agent_c].action == :create
    assert plans[agent_b].stale_device_agent_links == [stale_b.uid]
    assert plans[agent_c].stale_device_agent_links == [stale_c.uid]
    assert dry.ip_literal_devices == [literal_device.uid]
    assert dry.stale_device_agent_links == 2
    assert dry.alias_states_to_stale >= 1

    # Dry run mutated nothing.
    assert {:ok, %Agent{device_uid: device_uid}} = Agent.get_by_uid(agent_b, actor: actor)
    assert device_uid == chimera.uid

    assert {:ok, %Device{deleted_at: %DateTime{}}} =
             Device.get_by_uid(dev_b.uid, true, actor: actor)

    assert {:ok, %{reports: %{"agent-links" => report}}} =
             DireRemediation.run([
               {:mode, :execute},
               {:manifest_path, manifest_path("links")} | run_opts
             ])

    assert report.errors == 0
    assert report.ip_literal_fixed == 1

    # Agent A keeps the (rightfully owned) chimera.
    assert {:ok, %Agent{device_uid: agent_a_device}} = Agent.get_by_uid(agent_a, actor: actor)
    assert agent_a_device == chimera.uid

    # Agent B was repointed at its restored per-host device.
    assert {:ok, %Agent{device_uid: agent_b_device}} = Agent.get_by_uid(agent_b, actor: actor)
    assert agent_b_device == dev_b.uid
    assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(dev_b.uid, false, actor: actor)
    assert {:ok, %Device{agent_id: nil}} = Device.get_by_uid(stale_b.uid, false, actor: actor)

    # Agent B's identifier moved off the chimera onto the restored device.
    assert [identifier] = agent_identifiers(actor, agent_b)
    assert identifier.device_id == dev_b.uid
    assert live_device_agent_links(actor, agent_b) == [dev_b.uid]

    # Agent C got a freshly created per-host device.
    assert {:ok, %Agent{device_uid: agent_c_device}} = Agent.get_by_uid(agent_c, actor: actor)
    assert agent_c_device != chimera.uid
    assert {:ok, %Device{} = created} = Device.get_by_uid(agent_c_device, false, actor: actor)
    assert created.hostname == host_c
    assert created.agent_id == agent_c
    assert {:ok, %Device{agent_id: nil}} = Device.get_by_uid(stale_c.uid, false, actor: actor)
    assert live_device_agent_links(actor, agent_c) == [agent_c_device]

    # Poisoned alias is stale; relocation audit (reason "unmerge") exists.
    assert {:ok, %DeviceAliasState{state: :stale}} =
             Ash.get(DeviceAliasState, alias_state.id, actor: actor)

    assert {:ok, audits} = MergeAudit.get_by_device(dev_b.uid, actor: actor)

    assert Enum.any?(
             audits,
             &(&1.reason == "unmerge" and &1.from_device_id == chimera.uid and
                 &1.to_device_id == dev_b.uid)
           )

    assert {:ok, %Device{ip: nil}} = Device.get_by_uid(literal_device.uid, false, actor: actor)

    # Idempotent: everything is a keep on the second pass.
    assert {:ok, %{reports: %{"agent-links" => second}}} = DireRemediation.run(run_opts)
    assert second.keep == 3
    assert second.identifier_moves == 0
    assert second.stale_device_agent_links == 0
    assert second.target_agent_link_assignments == 0
    assert second.alias_states_to_stale == 0
  end

  # ---------------------------------------------------------------------------
  # proxmox-dups (4.4)
  # ---------------------------------------------------------------------------

  test "proxmox-dups: merges integration_id-churn rows corroborated as the same host",
       %{actor: actor} do
    seed = test_seed()
    hostname = "remtest-pmx-#{seed}"
    old_ref = "proxmox:v2:cluster-#{seed}:node:host01"
    new_ref = "proxmox:v2:cluster-#{seed}:node:host02"

    # Same physical node renamed within its cluster: the newer row
    # carries the old ref under legacy_integration_ids, so the two rows share a
    # cluster-scoped host reference and collapse (a name-keyed ref would not suffice).
    {:ok, older} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["proxmox"],
        metadata: %{"integration_id" => old_ref},
        last_seen_time: ~U[2026-05-09 02:21:03Z]
      })

    {:ok, newer} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["proxmox"],
        metadata: %{"integration_id" => new_ref, "legacy_integration_ids" => [old_ref]},
        last_seen_time: DateTime.utc_now()
      })

    assert {:ok, %{reports: %{"proxmox-dups" => dry}}} =
             DireRemediation.run(steps: ["proxmox-dups"], actor: actor)

    assert %{from: from, to: to} =
             Enum.find(dry.merge_plan, &(&1.hostname == hostname))

    assert from == older.uid
    assert to == newer.uid

    # Dry run mutated nothing.
    assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(older.uid, false, actor: actor)

    assert {:ok, %{reports: %{"proxmox-dups" => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["proxmox-dups"],
               actor: actor,
               manifest_path: manifest_path("pmx")
             )

    assert report.merged >= 1

    assert {:ok, %Device{deleted_at: %DateTime{}, deleted_reason: "merged"}} =
             Device.get_by_uid(older.uid, true, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(newer.uid, false, actor: actor)

    assert {:ok, audits} = MergeAudit.get_by_device(older.uid, actor: actor)

    assert Enum.any?(
             audits,
             &(&1.reason == "proxmox_dedupe" and &1.to_device_id == newer.uid)
           )

    # Idempotent: the group is gone on the second pass.
    assert {:ok, %{reports: %{"proxmox-dups" => second}}} =
             DireRemediation.run(steps: ["proxmox-dups"], actor: actor)

    refute Enum.any?(second.merge_plan, &(&1.hostname == hostname))
  end

  test "proxmox-dups: merges multi-homed rows corroborated by a shared strong ref",
       %{actor: actor} do
    seed = test_seed()
    hostname = "remtest-pmx-candidate-#{seed}"
    # Vmid-scoped ref: keyed on stable Proxmox identity, unique within its
    # scope, so sharing it is same-host evidence. (A shared bare-name ref
    # such as `proxmox:hypervisor:<node>` no longer corroborates — GitHub
    # #4051 — covered by the shared-name pair in the cross-cluster test.)
    host_ref = "proxmox:v2:lab:node:pve-a-#{seed}"

    # Two network-probed candidate rows for the SAME multi-homed node (shared
    # strong host reference) collapse; a same-hostname row that is neither
    # proxmox-sourced nor a candidate is out of scope entirely.
    {:ok, candidate_a} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{"proxmox_candidate" => true, "integration_id" => host_ref},
        last_seen_time: ~U[2026-05-09 02:21:03Z]
      })

    {:ok, candidate_b} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{"proxmox_candidate" => true, "integration_id" => host_ref},
        last_seen_time: DateTime.utc_now()
      })

    {:ok, non_candidate} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{},
        last_seen_time: DateTime.add(DateTime.utc_now(), 300, :second)
      })

    assert {:ok, %{reports: %{"proxmox-dups" => dry}}} =
             DireRemediation.run(steps: ["proxmox-dups"], actor: actor)

    assert %{from: from, to: to} =
             Enum.find(dry.merge_plan, &(&1.hostname == hostname))

    assert from == candidate_a.uid
    assert to == candidate_b.uid
    refute Enum.any?(dry.merge_plan, &(&1.to == non_candidate.uid))
  end

  test "proxmox-dups: NEVER merges same-hostname candidates from different clusters",
       %{actor: actor} do
    seed = test_seed()
    hostname = "pve02-#{seed}"

    # The multi-cluster reality: two DIFFERENT physical hosts named `pve02` in
    # separate Proxmox clusters (distinct host refs, no shared MAC). Merging
    # them would fuse distinct hardware — must never happen.
    {:ok, farm_pve02} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{
          "proxmox_candidate" => true,
          "integration_id" => "proxmox:hypervisor:farm01:pve02"
        },
        last_seen_time: ~U[2026-05-09 02:21:03Z]
      })

    {:ok, tonka_pve02} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{
          "proxmox_candidate" => true,
          "integration_id" => "proxmox:hypervisor:tonka01:pve02"
        },
        last_seen_time: DateTime.utc_now()
      })

    # A third pair shares the SAME bare-name host reference
    # (`proxmox:hypervisor:<name>`) with no shared MAC. Guest and node names
    # are reused across clusters (GitHub #4051), so a shared name token is
    # not same-host evidence and must never corroborate a merge either.
    {:ok, shared_a} =
      create_device(actor, %{
        hostname: "#{hostname}-shared",
        discovery_sources: ["sweep"],
        metadata: %{
          "proxmox_candidate" => true,
          "integration_id" => "proxmox:hypervisor:#{hostname}-shared"
        },
        last_seen_time: ~U[2026-05-09 02:21:03Z]
      })

    {:ok, shared_b} =
      create_device(actor, %{
        hostname: "#{hostname}-shared",
        discovery_sources: ["sweep"],
        metadata: %{
          "proxmox_candidate" => true,
          "integration_id" => "proxmox:hypervisor:#{hostname}-shared"
        },
        last_seen_time: DateTime.utc_now()
      })

    assert {:ok, %{reports: %{"proxmox-dups" => dry}}} =
             DireRemediation.run(steps: ["proxmox-dups"], actor: actor)

    refute Enum.any?(dry.merge_plan, &(&1.from in [farm_pve02.uid, tonka_pve02.uid]))
    refute Enum.any?(dry.merge_plan, &(&1.to in [farm_pve02.uid, tonka_pve02.uid]))
    refute Enum.any?(dry.merge_plan, &(&1.from in [shared_a.uid, shared_b.uid]))
    refute Enum.any?(dry.merge_plan, &(&1.to in [shared_a.uid, shared_b.uid]))
    assert dry.skipped_unrelated >= 4

    # Executing the step must not delete/merge either device.
    assert {:ok, %{reports: %{"proxmox-dups" => _}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["proxmox-dups"],
               actor: actor,
               manifest_path: manifest_path("pmx-xcluster")
             )

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(farm_pve02.uid, false, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(tonka_pve02.uid, false, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(shared_a.uid, false, actor: actor)

    assert {:ok, %Device{deleted_at: nil}} =
             Device.get_by_uid(shared_b.uid, false, actor: actor)
  end

  test "proxmox-dups: does NOT merge same-hostname candidates lacking any strong identity",
       %{actor: actor} do
    seed = test_seed()
    hostname = "pve03-#{seed}"

    # Network-probed L3-only fragments: same hostname, no MAC, no enrichment
    # ref. Without positive corroboration they are treated as distinct.
    {:ok, frag_a} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{"proxmox_candidate" => true},
        last_seen_time: ~U[2026-05-09 02:21:03Z]
      })

    {:ok, frag_b} =
      create_device(actor, %{
        hostname: hostname,
        discovery_sources: ["sweep"],
        metadata: %{"proxmox_candidate" => true},
        last_seen_time: DateTime.utc_now()
      })

    assert {:ok, %{reports: %{"proxmox-dups" => dry}}} =
             DireRemediation.run(steps: ["proxmox-dups"], actor: actor)

    refute Enum.any?(dry.merge_plan, &(&1.from in [frag_a.uid, frag_b.uid]))
    assert dry.skipped_unrelated >= 2
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_device(actor, attrs \\ %{}) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          uid: "sr:" <> Ecto.UUID.generate(),
          hostname: "dire-rem-test-#{test_seed()}",
          ip: "10.92.#{:rand.uniform(250)}.#{:rand.uniform(250)}"
        },
        attrs
      )
    )
    |> Ash.create(actor: actor)
  end

  # Run-unique seed: the scratch DB persists data across test runs, so
  # per-VM monotonic integers would collide with previous runs' rows.
  defp test_seed, do: :rand.uniform(1_000_000_000)

  defp create_agent(actor, agent_uid, attrs) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      Map.merge(
        %{
          uid: agent_uid,
          name: agent_uid,
          host: "dire-rem-host-#{agent_uid}",
          port: 50_051
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create()
  end

  defp seed_mac(actor, device_uid, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_uid,
      identifier_type: :mac,
      identifier_value: value,
      partition: "default",
      confidence: :strong,
      source: "test_seed"
    })
    |> Ash.create(actor: actor)
  end

  defp seed_agent_identifier(actor, agent_uid, device_uid) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_uid,
      identifier_type: :agent_id,
      identifier_value: agent_uid,
      partition: "default",
      confidence: :strong,
      source: "test_seed"
    })
    |> Ash.create(actor: actor)
  end

  defp seed_alias(actor, device_uid, ip) do
    DeviceAliasState
    |> Ash.Changeset.for_create(:detect, %{
      device_id: device_uid,
      alias_type: :ip,
      alias_value: ip
    })
    |> Ash.create(actor: actor)
  end

  defp mac_identifiers(%Device{uid: uid}, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == :mac and device_id == ^uid)
    |> Ash.read!(actor: actor)
  end

  defp agent_identifiers(actor, agent_uid) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^agent_uid)
    |> Ash.read!(actor: actor)
  end

  defp live_device_agent_links(actor, agent_uid) do
    Device
    |> Ash.Query.filter(agent_id == ^agent_uid)
    |> Ash.read!(actor: actor)
    |> unwrap_page()
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  defp unwrap_page(%Ash.Page.Keyset{results: results}), do: results
  defp unwrap_page(%Ash.Page.Offset{results: results}), do: results
  defp unwrap_page(results) when is_list(results), do: results

  defp age_identifier(id, %DateTime{} = last_seen) do
    %{num_rows: 1} =
      SQL.query!(
        Repo,
        "UPDATE platform.device_identifiers SET last_seen = $1 WHERE id = $2",
        [last_seen, id]
      )

    :ok
  end

  defp make_debris!(agent_uid) do
    %{num_rows: 1} =
      SQL.query!(
        Repo,
        "UPDATE platform.ocsf_agents SET created_time = $1, status = 'unavailable' WHERE uid = $2",
        [~U[2026-04-25 02:19:22Z], agent_uid]
      )

    :ok
  end

  defp make_stale_agent!(agent_uid) do
    %{num_rows: 1} =
      SQL.query!(
        Repo,
        """
        UPDATE platform.ocsf_agents
        SET created_time = $1,
            last_seen_time = $1,
            status = 'unavailable',
            is_healthy = false
        WHERE uid = $2
        """,
        [~U[2026-04-25 02:19:22Z], agent_uid]
      )

    :ok
  end

  # Unique, valid, universally-administered MAC (first octet 00).
  defp unique_mac do
    suffix =
      0xFFFFFFFFFF
      |> :rand.uniform()
      |> Integer.to_string(16)
      |> String.pad_leading(10, "0")

    "00" <> suffix
  end

  defp manifest_path(tag) do
    # Manifest.open/2 uses [:exclusive]; unique_integer repeats across BEAM
    # restarts on reused RBE /tmp and collides with leftover files.
    Path.join(
      System.tmp_dir!(),
      "dire_remediation_test_#{tag}_#{Ecto.UUID.generate()}.ndjson"
    )
  end

  defp assert_manifest_records(path, step, action) do
    assert File.exists?(path)

    entries =
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(entries, &(&1["step"] == step and &1["action"] == action))
  end
end
