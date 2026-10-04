defmodule ServiceRadar.DireTrace do
  @moduledoc """
  Records DIRE behavior as a trace of `formal/dire/DireResolution.tla` states.

  A trace test declares a synthetic physical world, drives the real ingestion entry points
  step by step, and after every step records the full model state:

    * observable state, read from the database: records and merge redirects, identifier
      owners, device addresses, confirmed IP aliases, interface-MAC claims;
    * ground truth, known only to the harness: DHCP leases (`ipAt`) and which physical device
      each identity-bearing observation came from (`phys`);
    * the step itself (`act`): its name, the identifiers it reported, the identity decisions
      the code made (telemetry) and recorded (persisted rows), and any merge caused by address
      evidence.

  The trace is compared byte for byte with the committed `formal/dire/traces/<name>.tla` and
  `.cfg`, which `//formal/dire` model-checks. With `DIRE_TRACE_WRITE=1` it is written instead.
  Anything the recorder cannot map to a model value raises rather than being dropped: that is
  how a gap between the model and the code surfaces.
  """

  import ExUnit.Assertions
  import ServiceRadar.DireTrace.Golden, only: [fun: 2, fun_map: 2, set: 1, str: 1, tla_bool: 1]

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.DireTrace.Golden
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.ArmisSourceSnapshot
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  require Ash.Query

  @telemetry_events [
    [:serviceradar, :identity_reconciler, :merge, :blocked],
    [:serviceradar, :identity_reconciler, :merge, :guard_blocked],
    [:serviceradar, :identity_reconciler, :alias, :invalidated],
    [:serviceradar, :identity_reconciler, :hostname_agreement, :refused],
    [:serviceradar, :identity_reconciler, :source_identity, :active_ip_conflict],
    [:serviceradar, :identity_reconciler, :source_identity, :source_override],
    [:serviceradar, :inventory, :source_retirement, :retired],
    [:serviceradar, :inventory, :source_succession, :merged],
    [:serviceradar, :inventory, :source_succession, :reviewed],
    [:serviceradar, :inventory, :source_succession, :skipped]
  ]

  defstruct [
    :name,
    :actor,
    :world,
    :real,
    :pre_uids,
    :handler,
    :source,
    demonstrates: nil,
    witness: nil,
    ip_at: %{},
    src_of: %{},
    names: %{},
    phys: %{},
    states: []
  ]

  # ---------------------------------------------------------------------------------------
  # World

  @doc """
  Starts a trace. `world` uses model constants:

      %{
        phys: ["h1", "h2"],
        ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h2", mac: "m2"}},
        src_of: %{"h1" => "a1", "h2" => "a2"},
        armis_macs: true,
        src_ids: ["a1", "a2"], hw_ids: ["m1", "m2"], laa_ids: [],
        ips: ["p1", "p2"],
        observers: ["Armis", "Discovery", "Arp", "Sweep"]
      }

  Optional keys: `host_of`, the hostname model value Armis reports for each device (by default
  the device's own name; cloned machines share one), `new_first_seen_ids`, the ids Armis reports
  with a first-seen time of their own, later than any sync of the trace (by default a re-keyed
  device keeps its first-seen time), and the model's `rekeys`, `fresh_ids`, `spare`,
  `agent_ids` and `agent_of`.

  The defect switches the trace is checked with are not part of the world: every trace reads
  `ResolutionBugs` from `formal/dire/CurrentBugs.tla`.

  Real values are synthetic: documentation-range MACs, documentation-range addresses and
  unique Armis ids.
  """
  def start(name, world, actor) do
    seed = System.unique_integer([:positive, :monotonic])

    real = %{
      mac:
        Map.new(Enum.with_index(world.hw_ids ++ world.laa_ids, 1), fn {m, i} ->
          prefix = if m in world.laa_ids, do: "02", else: "00"
          {m, "#{prefix}:00:5E:00:53:#{hex2(rem(seed + i, 200) + 16)}"}
        end),
      ip:
        Map.new(Enum.with_index(world.ips, 1), fn {p, i} ->
          {p, "198.51.100.#{rem(seed, 200) + i + 10}"}
        end),
      src: Map.new(Enum.with_index(world.src_ids, 1), fn {a, i} -> {a, "#{seed}#{i}"} end),
      agent: Map.new(Map.get(world, :agent_ids, []), fn g -> {g, "trace-agent-#{seed}-#{g}"} end),
      first_seen: first_seen_times(world)
    }

    test_pid = self()
    handler = "dire-trace-#{seed}"

    :ok =
      :telemetry.attach_many(
        handler,
        @telemetry_events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:dire_trace_event, event, measurements, metadata})
        end,
        nil
      )

    trace = %__MODULE__{
      name: name,
      actor: actor,
      world: world,
      real: real,
      pre_uids: MapSet.new(),
      handler: handler,
      ip_at: Map.new(Map.keys(world.ifaces), &{&1, "NoIp"}),
      src_of: world.src_of
    }

    trace = if world.src_ids == [], do: trace, else: create_source(trace)
    trace = %{trace | pre_uids: trace |> scoped_devices() |> MapSet.new(& &1.uid)}

    record(trace, quiet_act("Init"))
  end

  @doc "Detaches telemetry. Call from on_exit or at the end of the test."
  def stop(%__MODULE__{handler: handler}), do: :telemetry.detach(handler)

  # ---------------------------------------------------------------------------------------
  # Steps (each drives the real code, then records)

  @doc "DHCP: interface `x` leases model address `p`, or releases with `\"NoIp\"`."
  def lease(trace, x, p) do
    record(%{trace | ip_at: Map.put(trace.ip_at, x, p)}, quiet_act("Lease"))
  end

  @doc """
  Armis sync of physical device `h` under its current source id, seen at interface `x`'s address.
  The sync is stamped a minute ahead of now, so it is the newest observation of the address;
  `seen_offset: seconds` moves the stamp, for a sync that a later observation must outrank.
  """
  def armis(trace, h, x, opts \\ []) do
    sync_meta = %{"sync_service_id" => trace.source, "sync_run_id" => Ash.UUID.generate()}
    {ids, update} = armis_update(trace, h, x, opts, sync_meta)
    armis_step(trace, h, x, ids, update)
  end

  defp armis_step(trace, h, x, ids, update) do
    step(trace, "Armis", h, x, ids, fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
    end)
  end

  # The sync's identifiers and the update the sync service delivers for it. As the agent does, the
  # update names its integration source in `sync_meta` and scopes its integration id to it, so the
  # code files its identifiers under the source's own partition (`Ids.identifier_partition/2`).
  defp armis_update(trace, h, x, opts, sync_meta) do
    src =
      Map.get(trace.src_of, h) ||
        flunk("DIRE trace #{trace.name}: the source does not report #{h}")

    macs = if trace.world.armis_macs, do: macs_of(trace, h), else: []
    ip = real_ip!(trace, x)

    metadata = %{
      "integration_type" => "armis",
      "armis_device_id" => trace.real.src[src],
      "integration_id" => integration_id(trace, src),
      "_alias_last_seen_ip" => ip
    }

    # Sync times are truncated to the second (Normalize.parse_timestamp/1), and a claim on an
    # address whose holder was observed in the same second keeps the holder
    # (DeviceWrites.observed_after?/2). Each recorded step adds a second, so a later sync is
    # always observed later, however quickly the trace runs.
    seen_at =
      DateTime.to_iso8601(
        DateTime.add(
          DateTime.utc_now(),
          Keyword.get(opts, :seen_offset, 60) + length(trace.states),
          :second
        )
      )

    update =
      %{
        "ip" => ip,
        "hostname" => "trace-#{host_of(trace.world, h)}",
        "source" => "armis",
        "first_seen_time" => first_seen_time(trace, h, src),
        "last_seen_time" => seen_at,
        "metadata" => metadata
      }
      |> maybe_put_macs(Enum.map(macs, &trace.real.mac[&1]))
      |> Map.put("sync_meta", sync_meta)

    {[src | macs], update}
  end

  @doc """
  Mapper/SNMP discovery of `h` polled at interface `x`'s address: every interface's MAC and
  address. The step's identifiers are the globally-unique MACs only: the code must ignore a
  randomized MAC, which never identifies a device.
  """
  def discovery(trace, h, x) do
    ip = real_ip!(trace, x)
    # The mapper stamps its writes with second resolution, and an address only follows an
    # observation strictly newer than the holder's last one, so this poll must land in a later
    # second than any earlier step.
    Process.sleep(1_100)
    ts = DateTime.to_iso8601(DateTime.utc_now())
    hw_macs = trace.world.hw_ids

    records =
      trace.world.ifaces
      |> Enum.filter(fn {_x, iface} -> iface.phys == h end)
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.map(fn {{ix, iface}, index} ->
        own_ip = if trace.ip_at[ix] == "NoIp", do: [], else: [trace.real.ip[trace.ip_at[ix]]]

        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => index,
          "if_name" => "eth#{index}",
          "if_phys_address" => trace.real.mac[iface.mac],
          "ip_addresses" => own_ip,
          "timestamp" => ts
        }
      end)

    step(trace, "Discovery", h, x, Enum.filter(macs_of(trace, h), &(&1 in hw_macs)), fn ->
      assert :ok = MapperResultsIngestor.ingest_interfaces(Jason.encode!(records), %{})
    end)
  end

  @doc """
  ARP-style observation (netprobe census): interface `x`'s MAC and address. The step's
  identifiers are the globally-unique MAC only: the code neither looks up nor registers a
  randomized MAC from a census, and does not derive a uid from it, so a sighting of one is
  address-only and a new record is named by its address.
  """
  def arp(trace, h, x) do
    mac = trace.world.ifaces[x].mac
    ip = real_ip!(trace, x)
    real_mac = trace.real.mac[mac]
    ts = DateTime.to_iso8601(DateTime.utc_now())
    agent = "dire-trace-observer"

    update = %{
      "ip" => ip,
      "mac" => real_mac,
      "source" => "netprobe-census",
      "partition" => "default",
      "agent_id" => agent,
      "metadata" => %{
        "mac" => real_mac,
        "source" => "netprobe-census",
        "discovery_source" => "netprobe-census",
        "identity_source" => "netprobe_census",
        "agent_id" => agent,
        "_alias_last_seen_ip" => ip,
        "_alias_last_seen_at" => ts,
        ("ip_alias:" <> ip) => ts
      }
    }

    step(
      trace,
      "Arp",
      h,
      x,
      Enum.filter([mac], &(&1 in trace.world.hw_ids)),
      fn -> assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor) end
    )
  end

  @doc """
  Sweep: interface `x`'s address answered (`SweepResultsIngestor.ingest_results/3`, reported by
  an authenticated agent for a sweep group). It carries no identifier.
  """
  def sweep(trace, h, x) do
    ip = real_ip!(trace, x)
    agent_id = "dire-trace-sweeper"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "DIRE trace #{trace.name} #{ip}", partition: "default", agent_ids: []},
        actor: trace.actor
      )
      |> Ash.create()

    step(trace, "Sweep", h, x, [], fn ->
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results(
                 [%{"host_ip" => ip, "available" => true}],
                 Ash.UUID.generate(),
                 actor: trace.actor,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 authenticated_partition_id: "default",
                 config_version: "dire-trace"
               )
    end)
  end

  @doc "Agent check-in through the gateway: its agent id and the host's MACs, at `x`'s address."
  def agent(trace, h, x) do
    g = Map.fetch!(trace.world.agent_of, h)
    macs = macs_of(trace, h)

    attrs = %{
      hostname: "trace-#{h}",
      os: "linux",
      arch: "amd64",
      partition: "default",
      source_ip: real_ip!(trace, x),
      capabilities: [],
      host_macs: Enum.map(macs, &trace.real.mac[&1])
    }

    step(trace, "Agent", h, x, [g | macs], fn ->
      assert {:ok, _uid} = AgentGatewaySync.ensure_device_for_agent(trace.real.agent[g], attrs)
    end)
  end

  # ---------------------------------------------------------------------------------------
  # The source and the reconciler

  @doc """
  The source re-identifies physical device `h`: it reports `h` under model id `a` from now on, or
  stops reporting it with `"NoId"`. Nothing is ingested; the next sync or collection carries the
  change.
  """
  def rekey(trace, h, a) do
    src_of = if a == "NoId", do: Map.delete(trace.src_of, h), else: Map.put(trace.src_of, h, a)
    # The sync stamps a record's creation time to the second, and a succession keeps the record
    # created first, or the lower uid of two created in one second. In a deployment a re-key
    # comes long after the device's first record, so a record the new id lands on must be
    # created in a later second than the trace's records so far.
    if a != "NoId", do: Process.sleep(1_100)
    record(%{trace | src_of: src_of}, quiet_act("Rekey"))
  end

  @doc """
  An exact collection of the source, delivered as the sync service delivers one: every device the
  source reports now is synced at its first leased interface, stamped with one collection run (an
  Armis step each), and then the collection activates (a Collect step), as `SyncIngestorQueue`
  activates it after a run's final chunk (`ArmisSourceSnapshot.activate/3`). The run accounts for
  its population exactly: one row per reported device, none excluded, invalid or duplicated.
  """
  def collect(trace) do
    reported = Enum.sort(trace.src_of)
    count = length(reported)

    sync_meta = %{
      "sync_service_id" => trace.source,
      "sync_run_id" => Ash.UUID.generate(),
      "chunk_index" => 0,
      "total_chunks" => 1,
      "total_devices" => count,
      "is_final" => true,
      "population" => %{
        "raw_rows" => count,
        "excluded_rows" => 0,
        "invalid_rows" => 0,
        "valid_occurrences" => count,
        "distinct_source_ids" => count,
        "duplicate_occurrences" => 0,
        "conflicting_duplicate_ids" => 0
      }
    }

    {trace, updates} =
      Enum.reduce(reported, {trace, []}, fn {h, _a}, {acc, updates} ->
        x = leased_iface!(acc, h)
        {ids, update} = armis_update(acc, h, x, [], sync_meta)
        {armis_step(acc, h, x, ids, update), [update | updates]}
      end)

    step(trace, "Collect", nil, nil, [], fn ->
      assert :ok =
               ArmisSourceSnapshot.activate(Enum.reverse(updates), sync_meta, actor: trace.actor)
    end)
  end

  @doc """
  The retirement pass a collection queues (`SourceRetirementWorker`), run once T has passed: one
  `SourceRetirement.run/2` pass over the trace's source instance, with the settings the worker
  reads and a clock T past now, so the exact collections alone decide what retires (a Retire
  step).
  """
  def retire(trace) do
    settings =
      case DeviceCleanupSettings.get_settings(actor: trace.actor) do
        {:ok, %DeviceCleanupSettings{} = settings} -> settings
        _ -> DeviceCleanupSettings.create_settings!(%{}, actor: trace.actor)
      end

    instance = %{partition: "default", source: "armis", source_instance: trace.source}

    now =
      DateTime.add(DateTime.utc_now(), settings.source_retirement_min_absence_hours + 1, :hour)

    step(trace, "Retire", nil, nil, [], fn ->
      assert {:ok, %{status: :completed}} =
               SourceRetirement.run(instance, settings: settings, now: now, actor: trace.actor)
    end)
  end

  @doc """
  The reconciler's scheduled pass (`IdentityReconciler.reconcile_duplicates/1`), with the
  settings it reads. The pass scans the whole inventory; only what it does to the trace's records
  counts. Its duplicate pass has no model step: it pairs a record with the owner of the MAC in its
  MAC column only when that identifier sits in the record's own partition, and a source sync
  files its identifiers under the source's partition (`Ids.identifier_partition/2`). Its
  succession pass (`SourceSuccession`) is the model's Succeed and Review: a `source_succession`
  merge of two of the trace's records is a Succession step, and each `succession_review` decision
  about them a Review step after it. Any other merge, decision or event about the trace's records
  fails the trace, as does more than one succession in one pass, which the model takes as
  separate steps.
  """
  def reconcile(trace) do
    ensure_settings(trace)
    decisions_before = decision_counts(trace)
    audits_before = merge_rows(trace)

    assert {:ok, _stats} =
             IdentityReconciler.reconcile_duplicates(actor: trace.actor, trigger: :manual)

    trace = settle(trace)
    {successions, merges} = Enum.split_with(merge_rows(trace) -- audits_before, &succession?/1)

    if merges != [] do
      flunk("DIRE trace #{trace.name}: reconciler merged #{inspect(merges)}, not modeled")
    end

    {reviews, recorded} =
      trace
      |> recorded_since(decisions_before)
      |> Enum.split_with(&(&1.kind == "succession_review"))

    if recorded != [] do
      flunk("DIRE trace #{trace.name}: reconciler recorded #{inspect(recorded)}")
    end

    {review_events, events} = Enum.split_with(drain_events(), &reviewed_event?/1)
    {merged_events, events} = Enum.split_with(events, &merged_event?(trace, &1))
    Enum.each(events, &refute_trace_event!(trace, &1))

    if length(merged_events) != length(successions) do
      flunk(
        "DIRE trace #{trace.name}: succession merges #{inspect(successions)} " <>
          "against events #{inspect(merged_events)}"
      )
    end

    trace
    |> record_succession(successions)
    |> record_reviews(reviews, review_decisions(trace, review_events))
  end

  defp ensure_settings(trace) do
    case DeviceCleanupSettings.get_settings(actor: trace.actor) do
      {:ok, %DeviceCleanupSettings{}} -> :ok
      _ -> DeviceCleanupSettings.create_settings!(%{}, actor: trace.actor)
    end
  end

  defp succession?({_from, _to, reason}), do: reason == "source_succession"

  defp reviewed_event?({event, _m, _meta}),
    do: event == [:serviceradar, :inventory, :source_succession, :reviewed]

  defp merged_event?(trace, {event, _m, meta}) do
    event == [:serviceradar, :inventory, :source_succession, :merged] and
      Map.has_key?(trace.names, meta.predecessor) and Map.has_key?(trace.names, meta.successor)
  end

  defp record_succession(trace, []), do: trace

  defp record_succession(trace, [{from, to, _reason}]) do
    {from, to} = {name_of!(trace, from), name_of!(trace, to)}

    phys =
      Map.update(trace.phys, to, Map.get(trace.phys, from, []), fn held ->
        Enum.uniq(held ++ Map.get(trace.phys, from, []))
      end)

    record(%{trace | phys: phys}, quiet_act("Succession"))
  end

  defp record_succession(trace, successions) do
    flunk("DIRE trace #{trace.name}: one pass made the successions #{inspect(successions)}")
  end

  # One Review step per decision, in a fixed order. The model requires the telemetry and the
  # persisted rows to agree, so each step carries the decision from both.
  defp record_reviews(trace, recorded, decided) do
    Enum.reduce(Enum.uniq(recorded ++ decided), trace, fn decision, acc ->
      record(acc, %{
        quiet_act("Review")
        | decisions: Enum.filter([decision], &(&1 in decided)),
          recorded: Enum.filter([decision], &(&1 in recorded))
      })
    end)
  end

  defp review_decisions(trace, events) do
    events
    |> Enum.filter(fn {_e, _m, meta} ->
      Enum.any?(meta.device_uids, &Map.has_key?(trace.names, &1))
    end)
    |> Enum.map(fn {_e, _m, meta} ->
      recs = meta.device_uids |> Enum.map(&name_of!(trace, &1)) |> Enum.uniq() |> Enum.sort()
      %{kind: "succession_review", recs: recs}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp refute_trace_event!(trace, {event, _m, meta}) do
    involved = meta |> Map.values() |> List.flatten() |> Enum.any?(&Map.has_key?(trace.names, &1))

    if involved do
      flunk("DIRE trace #{trace.name}: reconciler event #{inspect(event)} #{inspect(meta)}")
    end
  end

  # The Armis integration source the trace's syncs and collections are attributed to.
  defp create_source(trace) do
    agent = "dire-trace-source-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: agent, name: agent},
      actor: trace.actor
    )
    |> Ash.create!(actor: trace.actor)

    source =
      IntegrationSource
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "DIRE trace #{trace.name} #{agent}",
          source_type: :armis,
          endpoint: "https://dire-trace.test",
          agent_id: agent
        },
        actor: trace.actor
      )
      |> Ash.create!(actor: trace.actor)

    %{trace | source: to_string(source.id)}
  end

  # The agent's scoped integration id (`syncsources.ScopedIntegrationID`) of model id `a`.
  defp integration_id(trace, a), do: "armis:#{trace.source}:device:#{trace.real.src[a]}"

  # The interface a sync of `h` is seen at: its first one holding a lease.
  defp leased_iface!(trace, h) do
    Enum.find_value(Enum.sort(trace.world.ifaces), fn {x, iface} ->
      if iface.phys == h and trace.ip_at[x] != "NoIp", do: x
    end) || flunk("DIRE trace #{trace.name}: #{h} holds no lease")
  end

  # ---------------------------------------------------------------------------------------
  # Recording

  # `ids` are the identifiers the step reports: the ones the code looks up and registers, and
  # the ones a new record's uid is derived from, which name it.
  defp step(trace, name, h, x, ids, fun) do
    observed_ip = if x, do: trace.ip_at[x], else: "NoIp"
    decisions_before = decision_counts(trace)
    audits_before = merge_rows(trace)
    fun.()
    trace = settle(trace)
    events = drain_events()

    raw_merges = merge_rows(trace) -- audits_before

    trace = name_new_records(trace, ids)

    new_merges =
      Enum.map(raw_merges, fn {from, to, reason} ->
        {name_of!(trace, from), name_of!(trace, to), reason}
      end)

    # The record an identity-bearing observation landed on: the one owning its identifiers,
    # or, when they are split across records (a refused conflict), the one holding its address.
    target = landing_record(trace, x, ids)

    phys =
      Enum.reduce(new_merges, trace.phys, fn {from, to, _reason}, acc ->
        Map.update(acc, to, Map.get(acc, from, []), &Enum.uniq(&1 ++ Map.get(acc, from, [])))
      end)

    phys =
      if ids != [] and target != nil,
        do: Map.update(phys, target, [h], &Enum.uniq([h | &1])),
        else: phys

    decisions = decisions_from(trace, events, ids)
    recorded = recorded_since(trace, decisions_before)

    address_merged =
      for {from, _to, reason} <- new_merges, reason == "ip_alias_conflict", do: from

    record(%{trace | phys: phys}, %{
      name: name,
      ids: ids,
      ip: observed_ip,
      decisions: decisions,
      recorded: recorded,
      address_merged: address_merged
    })
  end

  defp record(trace, act) do
    state = snapshot(trace, act)
    %{trace | states: trace.states ++ [state]}
  end

  # A step that observes nothing and decides nothing.
  defp quiet_act(name),
    do: %{name: name, ids: [], ip: "NoIp", decisions: [], recorded: [], address_merged: []}

  # Re-read until two consecutive snapshots agree, so asynchronous work has landed.
  defp settle(trace, attempts \\ 20) do
    a = raw_state(trace)
    Process.sleep(50)
    b = raw_state(trace)

    cond do
      a == b -> trace
      attempts > 0 -> settle(trace, attempts - 1)
      true -> flunk("DIRE trace #{trace.name}: state never settled")
    end
  end

  defp raw_state(trace) do
    {trace_devices(trace), merge_rows(trace), alias_rows(trace)}
  end

  # ---------------------------------------------------------------------------------------
  # Snapshot

  defp snapshot(trace, act) do
    devices = trace_devices(trace)
    by_uid = Map.new(devices, &{&1.uid, &1})

    Enum.each(devices, fn d ->
      Map.has_key?(trace.names, d.uid) ||
        flunk("DIRE trace #{trace.name}: unmapped record #{d.uid} (#{inspect(d.hostname)})")
    end)

    recs = all_recs(trace.world)

    %{
      "ipAt" => trace.ip_at,
      "created" => Map.new(recs, fn r -> {r, created?(trace, r, by_uid)} end),
      "into" => Map.new(recs, fn r -> {r, into_of(trace, r, by_uid)} end),
      "owner" => owners(trace),
      "recIp" => Map.new(recs, fn r -> {r, rec_ip(trace, r, by_uid)} end),
      "alias" => aliases(trace),
      "phys" => Map.new(recs, fn r -> {r, Enum.sort(Map.get(trace.phys, r, []))} end),
      "ifClaims" => if_claims(trace, recs),
      "act" => act
    }
  end

  defp all_recs(world),
    do:
      Map.get(world, :agent_ids, []) ++
        world.src_ids ++ world.hw_ids ++ world.laa_ids ++ world.ips

  # A named record exists. A seed soft-deleted as `seed_released` (D8) is written as a record
  # that no longer exists, as the model writes it.
  defp created?(trace, r, by_uid) do
    case uid_of(trace, r) do
      nil -> false
      uid -> not match?(%Device{deleted_reason: "seed_released"}, Map.get(by_uid, uid))
    end
  end

  defp into_of(trace, r, by_uid) do
    case uid_of(trace, r) do
      nil ->
        "NoRec"

      uid ->
        case Map.fetch!(by_uid, uid) do
          %Device{deleted_at: nil} ->
            "NoRec"

          %Device{deleted_reason: "merged"} ->
            {:ok, [audit | _]} = MergeAudit.get_merged_to(uid, actor: trace.actor)
            name_of!(trace, audit.to_device_id)

          %Device{deleted_reason: "seed_released"} ->
            "NoRec"

          %Device{deleted_reason: reason} ->
            flunk("DIRE trace #{trace.name}: #{r} tombstoned for #{inspect(reason)}, not modeled")
        end
    end
  end

  defp rec_ip(trace, r, by_uid) do
    with uid when is_binary(uid) <- uid_of(trace, r),
         %Device{ip: ip} when is_binary(ip) <- Map.get(by_uid, uid) do
      model_ip!(trace, ip)
    else
      _ -> "NoIp"
    end
  end

  defp owners(trace) do
    world = trace.world

    srcs =
      Map.new(world.src_ids, fn a ->
        owners =
          [
            owner_uid(trace, :armis_device_id, trace.real.src[a]),
            owner_uid(trace, :integration_id, integration_id(trace, a))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        case owners do
          [] -> {a, "NoRec"}
          [uid] -> {a, name_of!(trace, uid)}
          many -> flunk("DIRE trace #{trace.name}: #{a} owned by #{inspect(many)}")
        end
      end)

    macs =
      Map.new(world.hw_ids ++ world.laa_ids, fn m ->
        value = trace.real.mac[m] |> String.replace(":", "") |> String.upcase()

        case owner_uid(trace, :mac, value) do
          nil -> {m, "NoRec"}
          uid -> {m, name_of!(trace, uid)}
        end
      end)

    agents =
      Map.new(Map.get(world, :agent_ids, []), fn g ->
        case owner_uid(trace, :agent_id, trace.real.agent[g]) do
          nil -> {g, "NoRec"}
          uid -> {g, name_of!(trace, uid)}
        end
      end)

    srcs |> Map.merge(macs) |> Map.merge(agents)
  end

  defp owner_uid(trace, type, value) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == ^type and identifier_value == ^value)
    |> Ash.read!(actor: trace.actor)
    |> case do
      [] -> nil
      [%{device_id: uid}] -> uid
      many -> flunk("DIRE trace #{trace.name}: #{type} #{value} has #{length(many)} rows")
    end
  end

  defp aliases(trace) do
    rows = alias_rows(trace)

    Map.new(trace.world.ips, fn p ->
      ip = trace.real.ip[p]

      holders =
        for {value, uid, state} <- rows, value == ip, state in [:confirmed, :updated] do
          name_of!(trace, uid)
        end

      {p, holders |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp alias_rows(trace) do
    ips = Map.values(trace.real.ip)

    DeviceAliasState
    |> Ash.Query.filter(alias_type == :ip and alias_value in ^ips)
    |> Ash.read!(actor: trace.actor)
    |> Enum.map(&{&1.alias_value, &1.device_id, &1.state})
    |> Enum.sort()
  end

  defp if_claims(trace, recs) do
    macs_by_value =
      Map.new(trace.real.mac, fn {m, v} ->
        {v |> String.replace(":", "") |> String.upcase(), m}
      end)

    Map.new(recs, fn r ->
      claims =
        case uid_of(trace, r) do
          nil ->
            []

          uid ->
            uid
            |> InterfaceMacs.registered_values(trace.actor)
            |> Enum.map(&Map.get(macs_by_value, &1))
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()
        end

      {r, claims}
    end)
  end

  # ---------------------------------------------------------------------------------------
  # Decisions

  defp drain_events(acc \\ []) do
    receive do
      {:dire_trace_event, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp decisions_from(trace, events, ids) do
    events
    |> Enum.map(fn
      {[_, _, :merge, :blocked], _m, _meta} ->
        %{kind: "policy_block", recs: owners_of_ids(trace, ids)}

      {[_, _, :merge, :guard_blocked], _m, %{guard: :source_authority_conflict} = meta} ->
        %{kind: "source_block", recs: names_in(trace, meta)}

      {[_, _, :hostname_agreement, :refused], _m, meta} ->
        %{
          kind: "policy_block",
          recs:
            Enum.sort([
              name_of!(trace, meta.incoming_device_uid),
              name_of!(trace, meta.existing_device_uid)
            ])
        }

      {[_, _, :source_identity, :active_ip_conflict], _m, meta} ->
        %{
          kind: "ip_conflict",
          recs:
            Enum.sort([
              name_of!(trace, meta.incoming_device_uid),
              name_of!(trace, meta.existing_device_uid)
            ])
        }

      {[_, _, :source_identity, :source_override], _m, meta} ->
        %{
          kind: "source_override",
          recs:
            [meta.device_uid | meta.overridden_device_uids]
            |> Enum.map(&name_of!(trace, &1))
            |> Enum.uniq()
            |> Enum.sort()
        }

      {[_, _, :alias, :invalidated], _m, meta} ->
        %{
          kind: "alias_invalidated",
          recs:
            Enum.sort([name_of!(trace, meta.alias_device_id), name_of!(trace, meta.device_id)])
        }

      {[_, _, :source_retirement, :retired], _m, meta} ->
        %{kind: "source_id_retired", recs: [name_of!(trace, meta.device_uid)]}

      {event, _m, meta} ->
        flunk("DIRE trace #{trace.name}: unmodeled decision #{inspect(event)} #{inspect(meta)}")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A decision is recorded when it left a persisted identity decision this step: a new
  # `platform.identity_decisions` row, or one whose occurrence count moved. The recorded set is
  # read from those rows alone (kind and device set), independently of the telemetry above, so
  # the model's requirement that the two agree is checked against what was actually written.
  @recorded_kind %{
    policy_block: "policy_block",
    source_block: "source_block",
    alias_invalidated: "alias_invalidated",
    ip_conflict: "ip_conflict",
    source_override: "source_override",
    source_id_retired: "source_id_retired",
    succession_review: "succession_review"
  }

  defp recorded_since(trace, before) do
    named = trace.names |> Map.keys() |> MapSet.new()

    IdentityDecision
    |> Ash.read!(actor: trace.actor)
    |> Enum.filter(&(Map.get(before, &1.id) != &1.occurrence_count))
    |> Enum.filter(fn d -> Enum.any?(d.device_uids, &MapSet.member?(named, &1)) end)
    |> Enum.map(fn d ->
      kind =
        Map.get(@recorded_kind, d.decision_kind) ||
          flunk("DIRE trace #{trace.name}: unmodeled recorded decision #{inspect(d)}")

      recs = d.device_uids |> Enum.map(&name_of!(trace, &1)) |> Enum.uniq() |> Enum.sort()
      %{kind: kind, recs: recs}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp decision_counts(trace) do
    IdentityDecision |> Ash.read!(actor: trace.actor) |> Map.new(&{&1.id, &1.occurrence_count})
  end

  defp owners_of_ids(trace, ids) do
    owners = owners(trace)

    ids
    |> Enum.map(&Map.get(owners, &1, "NoRec"))
    |> Enum.reject(&(&1 == "NoRec"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp names_in(trace, meta) do
    [Map.get(meta, :from_device_id), Map.get(meta, :to_device_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&name_of!(trace, &1))
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------------------
  # Names

  # A record is named by the seed its uid was derived from, in the model's priority order:
  # a source-authoritative id, then a hardware MAC, then a randomized MAC, then the address.
  defp name_new_records(trace, ids) do
    new =
      trace
      |> trace_devices()
      |> Enum.reject(&Map.has_key?(trace.names, &1.uid))

    Enum.reduce(new, trace, fn device, acc ->
      name = seed_name(acc, ids, device)

      if name in Map.values(acc.names),
        do: flunk("DIRE trace #{acc.name}: two records named #{name} (#{device.uid})")

      %{acc | names: Map.put(acc.names, device.uid, name)}
    end)
  end

  defp seed_name(trace, ids, device) do
    w = trace.world

    cond do
      seed = Enum.find(Map.get(w, :agent_ids, []), &(&1 in ids)) -> seed
      seed = Enum.find(w.src_ids, &(&1 in ids)) -> seed
      seed = Enum.find(w.hw_ids, &(&1 in ids)) -> seed
      seed = Enum.find(w.laa_ids, &(&1 in ids)) -> seed
      is_binary(device.ip) -> model_ip!(trace, device.ip)
      true -> flunk("DIRE trace #{trace.name}: cannot name new record #{device.uid}")
    end
  end

  defp landing_record(trace, x, ids) do
    owners = owners(trace)

    candidates =
      ids
      |> Enum.map(&Map.get(owners, &1, "NoRec"))
      |> Enum.reject(&(&1 == "NoRec"))
      |> Enum.uniq()

    case candidates do
      [one] -> one
      [] -> nil
      _many -> address_holder(trace, x)
    end
  end

  # The live record holding the address the observation was made at.
  defp address_holder(trace, x) do
    ip = trace.real.ip[trace.ip_at[x]]

    trace
    |> trace_devices()
    |> Enum.find(&(is_nil(&1.deleted_at) and &1.ip == ip))
    |> case do
      nil -> nil
      d -> name_of!(trace, d.uid)
    end
  end

  defp uid_of(trace, r), do: Enum.find_value(trace.names, fn {uid, n} -> if n == r, do: uid end)

  defp name_of!(trace, uid),
    do: Map.get(trace.names, uid) || flunk("DIRE trace #{trace.name}: unnamed uid #{uid}")

  defp model_ip!(trace, ip) do
    Enum.find_value(trace.real.ip, fn {p, v} -> if v == ip, do: p end) ||
      flunk("DIRE trace #{trace.name}: address #{ip} is not in the world")
  end

  defp real_ip!(trace, x) do
    case trace.ip_at[x] do
      "NoIp" -> flunk("DIRE trace #{trace.name}: #{x} holds no lease")
      p -> trace.real.ip[p]
    end
  end

  defp macs_of(trace, h) do
    for {_x, i} <- Enum.sort(trace.world.ifaces), i.phys == h, i.mac != nil, do: i.mac
  end

  defp maybe_put_macs(update, []), do: update
  defp maybe_put_macs(update, macs), do: Map.put(update, "mac", Enum.join(macs, ","))

  # ---------------------------------------------------------------------------------------
  # Database reads

  @device_read_limit 1000

  # Reads only the devices the trace's world can have produced: the ones already named, the ones
  # holding a world address, and the ones owning a world identifier. Device :read is paginated,
  # so the read is sized explicitly and refuses to truncate.
  defp scoped_devices(trace) do
    uids = trace.names |> Map.keys() |> Enum.concat(identifier_owner_uids(trace)) |> Enum.uniq()
    ips = Map.values(trace.real.ip)

    devices =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^uids or ip in ^ips)
      |> Ash.read!(actor: trace.actor, page: [limit: @device_read_limit])
      |> Page.unwrap!()

    if length(devices) >= @device_read_limit,
      do: flunk("DIRE trace #{trace.name}: device read reached #{@device_read_limit} rows")

    devices
  end

  defp identifier_owner_uids(trace) do
    values = world_identifier_values(trace)

    DeviceIdentifier
    |> Ash.Query.filter(identifier_value in ^values)
    |> Ash.read!(actor: trace.actor)
    |> Enum.map(& &1.device_id)
  end

  defp world_identifier_values(trace) do
    src = Map.values(trace.real.src)

    macs =
      for mac <- Map.values(trace.real.mac),
          do: mac |> String.replace(":", "") |> String.upcase()

    src
    |> Enum.concat(Enum.map(trace.world.src_ids, &integration_id(trace, &1)))
    |> Enum.concat(macs)
    |> Enum.concat(Map.values(trace.real.agent))
  end

  defp trace_devices(trace) do
    trace
    |> scoped_devices()
    |> Enum.reject(&MapSet.member?(trace.pre_uids, &1.uid))
    |> Enum.sort_by(& &1.uid)
  end

  @doc """
  The trace's live records marked `source_retired` (add-source-id-succession D5), by model name.
  The resolution model does not express the mark, which the lifecycle model and its traces
  check (`ServiceRadar.DireLifecycleTrace`), so a test asserts it beside the trace.
  """
  def marked(trace) do
    trace
    |> trace_devices()
    |> Enum.filter(&(is_nil(&1.deleted_at) and not is_nil(&1.source_retired_at)))
    |> Enum.map(&name_of!(trace, &1.uid))
    |> Enum.sort()
  end

  defp merge_rows(trace) do
    uids = trace |> trace_devices() |> Enum.map(& &1.uid)

    MergeAudit
    |> Ash.Query.filter(from_device_id in ^uids)
    |> Ash.read!(actor: trace.actor)
    |> Enum.map(&{&1.from_device_id, &1.to_device_id, &1.reason})
    |> Enum.sort()
  end

  defp hex2(n), do: n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()

  # ---------------------------------------------------------------------------------------
  # Output

  @doc """
  Compares the trace with the committed files, or writes them with DIRE_TRACE_WRITE=1.

  `demonstrates: switch` also writes `Trace_<name>__knockout.cfg`: the same trace checked with
  `KnockoutBugs`, `ResolutionBugs` without that switch. `//formal/dire` requires TLC to reject the
  trace under it, which proves the real code exhibits the defect rather than merely being allowed
  to. Once the switch leaves `CurrentBugs.tla` the knockout equals the trace, TLC matches it, and
  its target fails until the knockout is deleted with the switch.

  `witness: property` also writes `Trace_<name>__witness.cfg`: the same trace checked against the
  model invariant `property` instead of `TraceIncomplete`. `//formal/dire` requires TLC to find a
  state of the trace that violates it, which proves the real code reaches a state the requirement
  forbids. A witness shows a defect no single step does, one the model allows step by step and
  whose harm is the state it leaves. Once the defect is fixed the trace no longer reaches that
  state, TLC reaches its end instead, and the target fails until the witness is deleted.

  `tamper: true` also emits one self-test variant per model variable, each altering that one
  variable in the final state. `//formal/dire` requires TLC to reject every variant, which is
  the proof that no variable is left unchecked.
  """
  def assert_golden!(trace, opts \\ []) do
    stop(trace)

    trace = %{
      trace
      | demonstrates: Keyword.get(opts, :demonstrates),
        witness: Keyword.get(opts, :witness)
    }

    Golden.golden!(trace.name, to_tla(trace), to_cfg(trace))

    if trace.demonstrates,
      do: Golden.golden_file!("Trace_#{trace.name}__knockout.cfg", to_cfg(trace, "KnockoutBugs"))

    if trace.witness,
      do:
        Golden.golden_file!(
          "Trace_#{trace.name}__witness.cfg",
          to_cfg(trace, "ResolutionBugs", trace.witness)
        )

    if Keyword.get(opts, :tamper, false) do
      Enum.each(tampered(trace), fn {var, tampered_trace} ->
        name = "#{trace.name}__tamper_#{var}"
        Golden.golden!(name, to_tla(%{tampered_trace | name: name}), to_cfg(tampered_trace))
      end)
    end

    :ok
  end

  @variables ["ipAt", "created", "into", "owner", "recIp", "alias", "phys", "ifClaims", "act"]

  defp tampered(trace) do
    {earlier, [last]} = Enum.split(trace.states, -1)

    Enum.map(@variables, fn var ->
      {var, %{trace | states: earlier ++ [Map.update!(last, var, &tamper_value(var, &1, trace))]}}
    end)
  end

  # Change exactly one entry of the variable, to another value of the same kind.
  defp tamper_value("act", act, _trace), do: %{act | name: "Sweep"}

  defp tamper_value(var, fun, trace) when is_map(fun) do
    [key | _] = fun |> Map.keys() |> Enum.sort()
    Map.update!(fun, key, &tamper_entry(var, &1, trace))
  end

  defp tamper_entry(_var, true, _trace), do: false
  defp tamper_entry(_var, false, _trace), do: true

  defp tamper_entry(_var, [], trace), do: [hd(trace.world.phys)]
  defp tamper_entry(_var, list, _trace) when is_list(list), do: []

  defp tamper_entry(var, "NoIp", trace) when var in ["ipAt", "recIp"], do: hd(trace.world.ips)
  defp tamper_entry(var, _ip, _trace) when var in ["ipAt", "recIp"], do: "NoIp"

  defp tamper_entry(var, "NoRec", trace) when var in ["owner", "into"],
    do: hd(all_recs(trace.world))

  defp tamper_entry(var, _rec, _trace) when var in ["owner", "into"], do: "NoRec"

  def to_tla(trace) do
    states = Enum.map_join(trace.states, ",\n", &("  " <> tla_state(&1)))

    """
    ---- MODULE Trace_#{trace.name} ----
    \\* Generated by ServiceRadar.DireTrace from the integration test that drives this scenario.
    \\* Regenerate with DIRE_TRACE_WRITE=1; do not edit by hand.
    EXTENDS DireResolutionTrace, CurrentBugs

    #{world_tla(trace.world)}#{knockout_tla(trace)}

    TheLog == <<
    #{states}
    >>
    ====
    """
  end

  # The switch set a knockout checks the trace with: today's switches without the demonstrated one.
  defp knockout_tla(%{demonstrates: nil}), do: ""

  defp knockout_tla(%{demonstrates: switch}),
    do: "\n\nKnockoutBugs == ResolutionBugs \\ {#{str(switch)}}"

  def to_cfg(trace, bugs \\ "ResolutionBugs", invariant \\ "TraceIncomplete") do
    w = trace.world

    """
    CONSTANTS
      Phys = #{set(w.phys)}
      Ifaces = #{set(Map.keys(w.ifaces))}
      IfPhys <- TraceIfPhys
      IfMac <- TraceIfMac
      SrcOf0 <- TraceSrcOf
      Rekeys = #{tla_bool(Map.get(w, :rekeys, false))}
      FreshIds = #{tla_bool(Map.get(w, :fresh_ids, true))}
      Spare = #{set(Map.get(w, :spare, []))}
      ArmisMacs = #{tla_bool(w.armis_macs)}
      HostOf <- TraceHostOf
      NewFirstSeenIds = #{set(Map.get(w, :new_first_seen_ids, []))}
      AgentIds = #{set(Map.get(w, :agent_ids, []))}
      AgentOf <- TraceAgentOf
      SrcIds = #{set(w.src_ids)}
      HwIds = #{set(w.hw_ids)}
      LaaIds = #{set(w.laa_ids)}
      Ips = #{set(w.ips)}
      Observers = #{set(w.observers)}
      NoId = NoId
      NoIp = NoIp
      NoRec = NoRec
      Bugs <- #{bugs}
      Unsafe = {}
      TraceLog <- TheLog
    INIT TraceInit
    NEXT TraceNext
    INVARIANT #{invariant}
    """
  end

  defp world_tla(w) do
    ifaces = Enum.sort(Map.keys(w.ifaces))

    """
    TraceIfPhys == #{fun(ifaces, fn x -> str(w.ifaces[x].phys) end)}
    TraceIfMac == #{fun(ifaces, fn x -> if(w.ifaces[x].mac, do: str(w.ifaces[x].mac), else: "NoId") end)}
    TraceSrcOf == #{fun(w.phys, fn h -> if(a = w.src_of[h], do: str(a), else: "NoId") end)}
    TraceHostOf == #{fun(w.phys, &str(host_of(w, &1)))}
    TraceAgentOf == #{fun(w.phys, fn h -> if(g = Map.get(w, :agent_of, %{})[h], do: str(g), else: "NoId") end)}\
    """
  end

  defp tla_state(s) do
    act = s["act"]

    "[ipAt |-> #{fun_map(s["ipAt"], &atom_or_str/1)}, " <>
      "created |-> #{fun_map(s["created"], &tla_bool/1)}, " <>
      "into |-> #{fun_map(s["into"], &atom_or_str/1)}, " <>
      "owner |-> #{fun_map(s["owner"], &atom_or_str/1)}, " <>
      "recIp |-> #{fun_map(s["recIp"], &atom_or_str/1)}, " <>
      "alias |-> #{fun_map(s["alias"], &set/1)}, " <>
      "phys |-> #{fun_map(s["phys"], &set/1)}, " <>
      "ifClaims |-> #{fun_map(s["ifClaims"], &set/1)}, " <>
      "act |-> [name |-> #{str(act.name)}, ids |-> #{set(act.ids)}, ip |-> #{atom_or_str(act.ip)}, " <>
      "decisions |-> #{decision_set(act.decisions)}, recorded |-> #{decision_set(act.recorded)}, " <>
      "addressMerged |-> #{set(act.address_merged)}]]"
  end

  defp decision_set(ds),
    do:
      "{" <>
        Enum.map_join(ds, ", ", &"[kind |-> #{str(&1.kind)}, recs |-> #{set(&1.recs)}]") <> "}"

  # The first-seen time Armis reports for device `h` under id `a` (the model's FsOf): the
  # device's own, before the trace, or for an id in `new_first_seen_ids` one of the id's own,
  # after every sync of the trace. Second precision, as the sync stores it.
  defp first_seen_times(world) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    devices =
      Map.new(Enum.with_index(world.phys, 1), fn {h, i} ->
        {h, DateTime.add(now, -30 * 86_400 + i * 60, :second)}
      end)

    ids =
      Map.new(Enum.with_index(Map.get(world, :new_first_seen_ids, []), 1), fn {a, i} ->
        {a, DateTime.add(now, 86_400 + i * 60, :second)}
      end)

    %{devices: devices, ids: ids}
  end

  defp first_seen_time(trace, h, a) do
    %{devices: devices, ids: ids} = trace.real.first_seen
    DateTime.to_iso8601(Map.get(ids, a) || Map.fetch!(devices, h))
  end

  # The hostname Armis reports for device `h`: its own name unless the world says otherwise.
  defp host_of(world, h), do: Map.get(Map.get(world, :host_of, %{}), h, h)

  # Model "none" markers are model values, not strings.
  defp atom_or_str(v) when v in ["NoIp", "NoRec", "NoId"], do: v
  defp atom_or_str(v), do: str(v)
end
