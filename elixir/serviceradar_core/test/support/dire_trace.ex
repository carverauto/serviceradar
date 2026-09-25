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
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  require Ash.Query

  @telemetry_events [
    [:serviceradar, :identity_reconciler, :merge, :blocked],
    [:serviceradar, :identity_reconciler, :merge, :guard_blocked],
    [:serviceradar, :identity_reconciler, :alias, :invalidated],
    [:serviceradar, :identity_reconciler, :source_identity, :active_ip_conflict],
    [:serviceradar, :identity_reconciler, :source_identity, :source_override]
  ]

  defstruct [
    :name,
    :actor,
    :world,
    :real,
    :pre_uids,
    :handler,
    ip_at: %{},
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
      agent: Map.new(Map.get(world, :agent_ids, []), fn g -> {g, "trace-agent-#{seed}-#{g}"} end)
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
      ip_at: Map.new(Map.keys(world.ifaces), &{&1, "NoIp"})
    }

    trace = %{trace | pre_uids: trace |> scoped_devices() |> MapSet.new(& &1.uid)}

    record(trace, %{
      name: "Init",
      ids: [],
      ip: "NoIp",
      decisions: [],
      recorded: [],
      address_merged: []
    })
  end

  @doc "Detaches telemetry. Call from on_exit or at the end of the test."
  def stop(%__MODULE__{handler: handler}), do: :telemetry.detach(handler)

  # ---------------------------------------------------------------------------------------
  # Steps (each drives the real code, then records)

  @doc "DHCP: interface `x` leases model address `p`, or releases with `\"NoIp\"`."
  def lease(trace, x, p) do
    trace = %{trace | ip_at: Map.put(trace.ip_at, x, p)}

    record(trace, %{
      name: "Lease",
      ids: [],
      ip: "NoIp",
      decisions: [],
      recorded: [],
      address_merged: []
    })
  end

  @doc "Armis sync of physical device `h`, seen at interface `x`'s address."
  def armis(trace, h, x) do
    src = Map.fetch!(trace.world.src_of, h)
    macs = if trace.world.armis_macs, do: macs_of(trace, h), else: []
    ip = real_ip!(trace, x)

    metadata = %{
      "integration_type" => "armis",
      "armis_device_id" => trace.real.src[src],
      "integration_id" => "armis:source-trace:device:#{trace.real.src[src]}",
      "_alias_last_seen_ip" => ip
    }

    seen_at = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60, :second))

    update =
      maybe_put_macs(
        %{
          "ip" => ip,
          "hostname" => "trace-#{h}",
          "source" => "armis",
          "last_seen_time" => seen_at,
          "metadata" => metadata
        },
        Enum.map(macs, &trace.real.mac[&1])
      )

    step(trace, "Armis", h, x, [src | macs], fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
    end)
  end

  @doc "Mapper/SNMP discovery of `h` polled at interface `x`'s address: every interface MAC."
  def discovery(trace, h, x) do
    ip = real_ip!(trace, x)
    ts = DateTime.to_iso8601(DateTime.utc_now())

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

    step(trace, "Discovery", h, x, macs_of(trace, h), fn ->
      assert :ok = MapperResultsIngestor.ingest_interfaces(Jason.encode!(records), %{})
    end)
  end

  @doc "ARP-style observation (netprobe census): interface `x`'s MAC and address."
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

    step(trace, "Arp", h, x, [mac], fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
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
  # Recording

  defp step(trace, name, h, x, ids, fun) do
    observed_ip = trace.ip_at[x]
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
      "created" => Map.new(recs, fn r -> {r, r in Map.values(trace.names)} end),
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
            owner_uid(trace, :integration_id, "armis:source-trace:device:#{trace.real.src[a]}")
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
    source_override: "source_override"
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
    |> Enum.concat(Enum.map(src, &"armis:source-trace:device:#{&1}"))
    |> Enum.concat(macs)
    |> Enum.concat(Map.values(trace.real.agent))
  end

  defp trace_devices(trace) do
    trace
    |> scoped_devices()
    |> Enum.reject(&MapSet.member?(trace.pre_uids, &1.uid))
    |> Enum.sort_by(& &1.uid)
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

  `tamper: true` also emits one self-test variant per model variable, each altering that one
  variable in the final state. `//formal/dire` requires TLC to reject every variant, which is
  the proof that no variable is left unchecked.
  """
  def assert_golden!(trace, opts \\ []) do
    stop(trace)
    Golden.golden!(trace.name, to_tla(trace), to_cfg(trace))

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

    #{world_tla(trace.world)}

    TheLog == <<
    #{states}
    >>
    ====
    """
  end

  def to_cfg(trace) do
    w = trace.world

    """
    CONSTANTS
      Phys = #{set(w.phys)}
      Ifaces = #{set(Map.keys(w.ifaces))}
      IfPhys <- TraceIfPhys
      IfMac <- TraceIfMac
      SrcOf <- TraceSrcOf
      ArmisMacs = #{tla_bool(w.armis_macs)}
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
      Bugs <- ResolutionBugs
      TraceLog <- TheLog
    INIT TraceInit
    NEXT TraceNext
    INVARIANT TraceIncomplete
    """
  end

  defp world_tla(w) do
    ifaces = Enum.sort(Map.keys(w.ifaces))

    """
    TraceIfPhys == #{fun(ifaces, fn x -> str(w.ifaces[x].phys) end)}
    TraceIfMac == #{fun(ifaces, fn x -> if(w.ifaces[x].mac, do: str(w.ifaces[x].mac), else: "NoId") end)}
    TraceSrcOf == #{fun(w.phys, fn h -> if(a = w.src_of[h], do: str(a), else: "NoId") end)}
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

  # Model "none" markers are model values, not strings.
  defp atom_or_str(v) when v in ["NoIp", "NoRec", "NoId"], do: v
  defp atom_or_str(v), do: str(v)
end
