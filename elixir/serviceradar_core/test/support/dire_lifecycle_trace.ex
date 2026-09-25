defmodule ServiceRadar.DireLifecycleTrace do
  @moduledoc """
  Records the DIRE device lifecycle as a trace of `formal/dire/DireLifecycle.tla` states.

  A trace test declares a synthetic world (model device names, typed identifiers, addresses),
  drives the real lifecycle entry points step by step -- ingest, merge, unmerge, soft delete,
  sweep restore, agent check-in, purge -- and after every step records the full model state,
  read from the database:

    * `status`/`reason`: whether each device row is absent, live, tombstoned or purged, and the
      class of its `deleted_reason`;
    * `owner`: which device owns each world identifier (`device_identifiers`);
    * `ipOf`: each device's address;
    * `audit`: the `merge_audit` rows, oldest first;
    * `work`: the in-flight ingest item between an ingest's resolve and its write;
    * `act`: the step, with the devices whose `identity_revision` it moved (`bumped`).

  An ingest is logged as the model's two steps: `StartWork` (the uid the source reached and
  the device DIRE resolved it to) and `Commit`. The code runs them in one call, so `work` is
  never stale here; a merge landing between the two is the fence's case and stays model-only
  until the fence is enforced (#4618).

  Two values are ghosts the database cannot record, and the harness supplies them: which
  identifiers the merged-away device owned when a merge ran (`srcIds`), and the insertion order
  of `merge_audit` rows (their `created_at` has one-second precision, so two rows can tie).

  The trace is compared byte for byte with the committed `formal/dire/traces/<name>.tla` and
  `.cfg`, which `//formal/dire` model-checks. With `DIRE_TRACE_WRITE=1` it is written instead.
  Anything the recorder cannot map to a model value raises rather than being dropped.
  """

  import ExUnit.Assertions
  import ServiceRadar.DireTrace.Golden, only: [fun_map: 2, set: 1, str: 1, tla_bool: 1]

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.DireTrace.Golden
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  require Ash.Query

  # Resolver @max_canonical_follow_depth.
  @follow_depth 5

  defstruct [
    :name,
    :actor,
    :world,
    :real,
    pre_uids: MapSet.new(),
    names: %{},
    last_reason: %{},
    seen: MapSet.new(),
    audit_order: [],
    src_ids: %{},
    states: []
  ]

  # ---------------------------------------------------------------------------------------
  # World

  @doc """
  Starts a trace. `world` uses model constants:

      %{
        devices: ["d1", "d2"],
        ids: %{"i1" => :src, "i2" => :mac, "i3" => :agent},
        ips: ["p1", "p2"],
        bugs: [...]
      }

  A `:src` identifier is an Armis device id (with its integration id), `:mac` a hardware MAC,
  `:agent` an agent id. Real values are synthetic: documentation-range MACs, the test helpers'
  address range, generated ids.
  """
  def start(name, world, actor) do
    seed = System.unique_integer([:positive, :monotonic])

    real_ids =
      world.ids
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {{i, type}, n} -> {i, real_id(type, seed, n)} end)

    real = %{
      ids: real_ids,
      ip:
        Map.new(Enum.with_index(world.ips, 1), fn {p, n} ->
          {p, "100.125.#{rem(seed, 250) + 1}.#{n + 10}"}
        end)
    }

    trace = %__MODULE__{name: name, actor: actor, world: world, real: real}
    trace = %{trace | pre_uids: trace |> read_devices() |> MapSet.new(& &1.uid)}

    log(trace, raw(trace), [], act("Init"))
  end

  defp real_id(:src, seed, n), do: {:src, "#{seed}0#{n}"}

  defp real_id(:mac, seed, n), do: {:mac, "00:00:5E:00:53:#{hex2(rem(seed + n, 200) + 16)}"}

  defp real_id(:agent, seed, n), do: {:agent, "trace-lifecycle-agent-#{seed}-#{n}"}

  # ---------------------------------------------------------------------------------------
  # Ingest steps: StartWork + Commit

  @doc "Armis sync reporting source identifier `i` at address `p`."
  def armis(trace, i, p) do
    {:src, value} = trace.real.ids[i]

    update = %{
      "ip" => trace.real.ip[p],
      "hostname" => "trace-#{i}",
      "source" => "armis",
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => value,
        "integration_id" => integration_id(value)
      }
    }

    ingest(trace, [i], p, nil, fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
    end)
  end

  @doc "Census (ARP) observation of hardware MAC `i` at address `p`."
  def census(trace, i, p) do
    {:mac, mac} = trace.real.ids[i]
    ip = trace.real.ip[p]

    update = %{
      "ip" => ip,
      "mac" => mac,
      "source" => "netprobe-census",
      "partition" => "default",
      "metadata" => %{
        "mac" => mac,
        "source" => "netprobe-census",
        "discovery_source" => "netprobe-census",
        "identity_source" => "netprobe_census"
      }
    }

    ingest(trace, [i], p, nil, fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
    end)
  end

  @doc """
  A sync update that carries device `d`'s uid and address `p` and no strong identifier, as a
  source that already knows the device does.
  """
  def by_uid(trace, d, p) do
    uid = uid_of!(trace, d)

    update = %{
      "device_id" => uid,
      "ip" => trace.real.ip[p],
      "hostname" => "trace-#{d}",
      "source" => "netbox",
      "metadata" => %{}
    }

    ingest(trace, [], p, d, fn ->
      assert :ok = SyncIngestor.ingest_updates([update], actor: trace.actor)
    end)
  end

  @doc """
  Agent check-in through the gateway with agent identifier `i`, at address `p`. When it clears
  the tombstone of the device already owning `i`, it is the model's `GatewaySync`; otherwise it
  resolves and writes, as any ingest does.
  """
  def agent(trace, i, p) do
    {:agent, agent_id} = trace.real.ids[i]

    attrs = %{
      hostname: "trace-#{i}",
      os: "linux",
      arch: "amd64",
      partition: "default",
      source_ip: trace.real.ip[p],
      capabilities: [],
      host_macs: []
    }

    fun = fn -> assert {:ok, _uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs) end

    before = raw(trace)
    holder = before.owners[i]

    if holder && tomb?(before, holder) do
      {trace, before, after_} = run(trace, before, fun)
      d = name_of!(trace, holder)

      if !live?(after_, holder),
        do: flunk("DIRE lifecycle trace #{trace.name}: agent check-in left #{d} tombstoned")

      log(trace, after_, [], act("GatewaySync", d, "NoDev", 0, bumped(trace, before, after_)))
    else
      ingest(trace, [i], p, nil, fun)
    end
  end

  # `carried` is the model device whose uid the source carries; nil when it reports identifiers.
  defp ingest(trace, ids, p, carried, fun) do
    before = raw(trace)
    {trace, before, after_} = run(trace, before, fun)

    target = landing!(trace, after_, ids, p)

    reached =
      cond do
        carried != nil -> carried
        (owner = single_owner(trace, before, ids)) != nil -> owner
        true -> target
      end

    trace = log(trace, before, [target], act("StartWork", reached, target))

    name =
      if unchanged?(trace, before, after_, target), do: "CommitDropped", else: "Commit"

    log(trace, after_, [], act(name, "NoDev", target, 0, bumped(trace, before, after_)))
  end

  # The device the write landed on: the one owning the reported identifiers, or, for a source
  # that carries a uid, the live device now holding the reported address.
  defp landing!(trace, after_, ids, p) do
    if ids == [] do
      ip = trace.real.ip[p]

      after_.devices
      |> Enum.find(fn {_uid, d} -> is_nil(d.deleted_at) and d.ip == ip end)
      |> case do
        {uid, _} -> name_of!(trace, uid)
        nil -> flunk("DIRE lifecycle trace #{trace.name}: no live device at #{p} after ingest")
      end
    else
      single_owner(trace, after_, ids) ||
        flunk("DIRE lifecycle trace #{trace.name}: #{inspect(ids)} not owned after ingest")
    end
  end

  defp single_owner(trace, raw, ids) do
    ids
    |> Enum.map(&raw.owners[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      [uid] ->
        name_of!(trace, uid)

      many ->
        flunk("DIRE lifecycle trace #{trace.name}: #{inspect(ids)} split over #{inspect(many)}")
    end
  end

  defp unchanged?(trace, before, after_, d) do
    uid = uid_of!(trace, d)

    Map.get(before.devices, uid) == Map.get(after_.devices, uid) and
      before.owners == after_.owners
  end

  # ---------------------------------------------------------------------------------------
  # Lifecycle steps

  @doc """
  `MergeEngine.merge_devices/3` merges `f` into `t`, with an automatic reason (`:auto`) or an
  administrative one (`:manual`).
  """
  def merge(trace, f, t, kind) do
    from = uid_of!(trace, f)
    to = uid_of!(trace, t)
    reason = if kind == :manual, do: "manual_trace", else: "identity_resolution"

    merged(trace, fn ->
      assert :ok = MergeEngine.merge_devices(from, to, actor: trace.actor, reason: reason)
    end)
  end

  @doc """
  The resolver finds the identifiers `ids` owned by different devices and merges them
  (`Resolver.lookup_by_strong_identifiers/3` -> `MergeEngine.merge_conflicting_devices/4`). The
  code picks the survivor; the details record every match, both sides.
  """
  def conflict(trace, ids) do
    update = %{metadata: %{}, partition: "default", ip: ""}

    update =
      Enum.reduce(ids, update, fn i, acc ->
        case trace.real.ids[i] do
          {:src, v} ->
            metadata =
              Map.merge(acc.metadata, %{
                "integration_type" => "armis",
                "armis_device_id" => v,
                "integration_id" => integration_id(v)
              })

            %{acc | metadata: metadata}

          {:mac, mac} ->
            Map.put(acc, :mac, mac)

          {:agent, v} ->
            %{acc | metadata: Map.put(acc.metadata, "agent_id", v)}
        end
      end)

    merged(trace, fn ->
      assert {:ok, _canonical} =
               Resolver.lookup_by_strong_identifiers(
                 Ids.extract_strong_identifiers(update),
                 trace.actor
               )
    end)
  end

  # Runs one merge and logs it as the model's Merge(f, t): the pair is read from the new row.
  defp merged(trace, fun) do
    before = raw(trace)
    {trace, before, after_} = run(trace, before, fun)

    case new_rows(trace, before, after_) do
      [%{event_id: id, from_device_id: from, to_device_id: to, reason: reason}]
      when reason != "unmerge" ->
        f = name_of!(trace, from)
        trace = %{trace | src_ids: Map.put(trace.src_ids, id, owned(trace, before, f))}
        row = length(trace.audit_order)

        log(
          trace,
          after_,
          [],
          act("Merge", f, name_of!(trace, to), row, bumped(trace, before, after_))
        )

      rows ->
        flunk("DIRE lifecycle trace #{trace.name}: expected one merge row, got #{inspect(rows)}")
    end
  end

  @doc """
  `MergeEngine.unmerge_device/2` on `u`, or with `:latest` on the device the newest merge
  row merged away (for a merge whose survivor the code chose).
  """
  def unmerge(trace, :latest) do
    raw = raw(trace)

    trace.audit_order
    |> Enum.map(&raw.audit[&1])
    |> Enum.filter(&(&1.reason != "unmerge"))
    |> List.last()
    |> case do
      nil -> flunk("DIRE lifecycle trace #{trace.name}: nothing to unmerge")
      row -> unmerge(trace, name_of!(trace, row.from_device_id))
    end
  end

  def unmerge(trace, u) do
    uid = uid_of!(trace, u)
    before = raw(trace)

    # The model's LatestMergeRow(u): the newest merge row from u, by insertion order.
    k =
      trace.audit_order
      |> Enum.with_index(1)
      |> Enum.filter(fn {id, _k} ->
        row = before.audit[id]
        row.from_device_id == uid and row.reason != "unmerge"
      end)
      |> List.last()
      |> case do
        {_id, k} -> k
        nil -> flunk("DIRE lifecycle trace #{trace.name}: #{u} has no merge row")
      end

    {trace, before, after_} =
      run(trace, before, fn ->
        assert :ok = MergeEngine.unmerge_device(uid, actor: trace.actor)
      end)

    case new_rows(trace, before, after_) do
      [%{reason: "unmerge", from_device_id: survivor, to_device_id: ^uid}] ->
        s = name_of!(trace, survivor)
        log(trace, after_, [], act("Unmerge", u, s, k, bumped(trace, before, after_)))

      rows ->
        flunk("DIRE lifecycle trace #{trace.name}: unmerge #{u} wrote #{inspect(rows)}")
    end
  end

  @doc "An administrative soft delete of `d` (`Device :soft_delete`)."
  def soft_delete(trace, d) do
    uid = uid_of!(trace, d)
    before = raw(trace)

    {trace, before, after_} =
      run(trace, before, fn ->
        {:ok, device} = Device.get_by_uid(uid, false, actor: trace.actor)

        assert {:ok, _} =
                 Device.soft_delete(device, "trace_admin_delete", "dire-trace",
                   actor: trace.actor
                 )
      end)

    log(trace, after_, [], act("SoftDelete", d, "NoDev", 0, bumped(trace, before, after_)))
  end

  @doc """
  An available sweep result for address `p`, reported by an authenticated agent for a sweep
  group (`SweepResultsIngestor.ingest_results/3`).
  """
  def sweep(trace, p) do
    before = raw(trace)
    agent_id = "trace-lifecycle-sweeper-#{trace.name}"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "DIRE lifecycle trace #{trace.name} #{p}", partition: "default", agent_ids: []},
        actor: trace.actor
      )
      |> Ash.create()

    {trace, before, after_} =
      run(trace, before, fn ->
        assert {:ok, _stats} =
                 SweepResultsIngestor.ingest_results(
                   [%{"host_ip" => trace.real.ip[p], "available" => true}],
                   Ash.UUID.generate(),
                   actor: trace.actor,
                   sweep_group_id: group.id,
                   agent_id: agent_id,
                   authenticated_agent_id: agent_id,
                   authenticated_partition_id: "default",
                   config_version: "dire-lifecycle-trace"
                 )
      end)

    restored =
      for {uid, d} <- before.devices, not is_nil(d.deleted_at), live?(after_, uid), do: uid

    case restored do
      [uid] ->
        log(
          trace,
          after_,
          [],
          act("SweepRestore", name_of!(trace, uid), "NoDev", 0, bumped(trace, before, after_))
        )

      other ->
        flunk("DIRE lifecycle trace #{trace.name}: sweep at #{p} restored #{inspect(other)}")
    end
  end

  @doc "`DeviceCleanupWorker` hard-deletes the tombstoned `d` (its retention cutoff passed)."
  def purge(trace, d) do
    uid = uid_of!(trace, d)
    before = raw(trace)

    {trace, before, after_} =
      run(trace, before, fn ->
        assert {_stats, 1} =
                 DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, [%{uid: uid}])
      end)

    log(trace, after_, [], act("Purge", d, "NoDev", 0, bumped(trace, before, after_)))
  end

  # ---------------------------------------------------------------------------------------
  # Recording

  defp run(trace, before, fun) do
    fun.()
    after_ = settle(trace)
    trace = trace |> name_new(after_) |> order_audit(after_)
    {trace, before, after_}
  end

  defp act(name, u \\ "NoDev", v \\ "NoDev", row \\ 0, bumped \\ []),
    do: %{name: name, u: u, v: v, row: row, stale: false, bumped: bumped}

  defp log(trace, raw, work, act) do
    state = snapshot(trace, raw, work, act)

    last_reason =
      Enum.reduce(state.status, trace.last_reason, fn
        {d, "tomb"}, acc -> Map.put(acc, d, state.reason[d])
        _, acc -> acc
      end)

    seen = raw.devices |> Map.keys() |> MapSet.new() |> MapSet.union(trace.seen)
    %{trace | states: trace.states ++ [state], last_reason: last_reason, seen: seen}
  end

  # Re-read until two consecutive reads agree, so asynchronous work has landed.
  defp settle(trace, attempts \\ 20) do
    a = raw(trace)
    Process.sleep(50)
    b = raw(trace)

    cond do
      a == b -> b
      attempts > 0 -> settle(trace, attempts - 1)
      true -> flunk("DIRE lifecycle trace #{trace.name}: state never settled")
    end
  end

  # The devices whose identity_revision moved, plus rows that appeared or disappeared: a pin
  # taken on a row that did not exist, or that is gone, is stale either way.
  defp bumped(trace, before, after_) do
    uids = Enum.uniq(Map.keys(before.devices) ++ Map.keys(after_.devices))

    uids
    |> Enum.filter(fn uid ->
      case {Map.get(before.devices, uid), Map.get(after_.devices, uid)} do
        {nil, nil} -> false
        {nil, _} -> true
        {_, nil} -> true
        {a, b} -> a.identity_revision != b.identity_revision
      end
    end)
    |> Enum.map(&name_of!(trace, &1))
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------------------
  # Snapshot

  defp snapshot(trace, raw, work, act) do
    devices = trace.world.devices

    %{
      status: Map.new(devices, &{&1, status(trace, raw, &1)}),
      reason: Map.new(devices, &{&1, reason(trace, raw, &1)}),
      owner:
        Map.new(Map.keys(trace.world.ids), fn i ->
          {i, if(uid = raw.owners[i], do: name_of!(trace, uid), else: "NoDev")}
        end),
      ipOf: Map.new(devices, &{&1, ip_of(trace, raw, &1)}),
      audit: Enum.map(trace.audit_order, &audit_row(trace, raw.audit[&1])),
      work: Enum.map(work, &%{target: &1, stale: false}),
      act: act
    }
  end

  defp status(trace, raw, d) do
    case uid_of(trace, d) do
      nil -> "absent"
      uid -> row_status(trace, raw, uid)
    end
  end

  # A missing row is purged only if an earlier logged state had it; a device named by this
  # step's write did not exist in the step's pre-state.
  defp row_status(trace, raw, uid) do
    case Map.get(raw.devices, uid) do
      nil -> if MapSet.member?(trace.seen, uid), do: "purged", else: "absent"
      %{deleted_at: nil} -> "live"
      _ -> "tomb"
    end
  end

  defp reason(trace, raw, d) do
    case status(trace, raw, d) do
      "absent" -> "none"
      "purged" -> Map.get(trace.last_reason, d, "none")
      _ -> reason_class(raw.devices[uid_of!(trace, d)].deleted_reason)
    end
  end

  defp reason_class(nil), do: "none"
  defp reason_class("merged"), do: "merged"
  defp reason_class(_other), do: "other"

  defp ip_of(trace, raw, d) do
    with uid when is_binary(uid) <- uid_of(trace, d),
         %{ip: ip} when is_binary(ip) <- Map.get(raw.devices, uid) do
      Enum.find_value(trace.real.ip, fn {p, v} -> if v == ip, do: p end) ||
        flunk("DIRE lifecycle trace #{trace.name}: #{d} holds #{ip}, not a world address")
    else
      _ -> "NoIp"
    end
  end

  defp audit_row(trace, row) do
    merge? = row.reason != "unmerge"

    src_ids =
      if merge?,
        do:
          Map.get(trace.src_ids, row.event_id) ||
            flunk(
              "DIRE lifecycle trace #{trace.name}: merge row #{row.event_id} not made by a step"
            ),
        else: []

    %{
      from: name_of!(trace, row.from_device_id),
      to: name_of!(trace, row.to_device_id),
      kind: if(merge?, do: "merge", else: "unmerge"),
      ids: detail_ids(trace, row.details),
      srcIds: src_ids,
      recent: true
    }
  end

  # The identifiers a merge row's details name (merge_conflicting_devices/4 lists the matches).
  defp detail_ids(trace, details) do
    details = details || %{}

    (details["identifiers"] || details[:identifiers] || [])
    |> Enum.map(fn m ->
      key =
        {to_string(m["type"] || m[:type]), m["value"] || m[:value]}

      Enum.find_value(trace.real.ids, fn {i, real} ->
        rows = for {type, value} <- identifier_rows(real), do: {to_string(type), value}
        if key in rows, do: i
      end) || flunk("DIRE lifecycle trace #{trace.name}: merge details name #{inspect(key)}")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp owned(trace, raw, d) do
    uid = uid_of!(trace, d)
    for {i, ^uid} <- raw.owners, do: i
  end

  defp tomb?(raw, uid), do: match?(%{deleted_at: %_{}}, Map.get(raw.devices, uid))
  defp live?(raw, uid), do: match?(%{deleted_at: nil}, Map.get(raw.devices, uid))

  # ---------------------------------------------------------------------------------------
  # Names

  defp name_new(trace, raw) do
    new = raw.devices |> Map.keys() |> Enum.reject(&Map.has_key?(trace.names, &1)) |> Enum.sort()

    Enum.reduce(new, trace, fn uid, acc ->
      used = Map.values(acc.names)

      case Enum.find(acc.world.devices, &(&1 not in used)) do
        nil ->
          flunk(
            "DIRE lifecycle trace #{acc.name}: more devices than #{inspect(acc.world.devices)}"
          )

        d ->
          %{acc | names: Map.put(acc.names, uid, d)}
      end
    end)
  end

  defp order_audit(trace, raw) do
    new =
      raw.audit
      |> Map.keys()
      |> Enum.reject(&(&1 in trace.audit_order))

    case new do
      [] ->
        trace

      [id] ->
        %{trace | audit_order: trace.audit_order ++ [id]}

      many ->
        flunk("DIRE lifecycle trace #{trace.name}: one step wrote #{length(many)} audit rows")
    end
  end

  defp new_rows(trace, before, after_) do
    for id <- trace.audit_order, not Map.has_key?(before.audit, id), do: after_.audit[id]
  end

  defp uid_of(trace, d), do: Enum.find_value(trace.names, fn {uid, n} -> if n == d, do: uid end)

  defp uid_of!(trace, d),
    do: uid_of(trace, d) || flunk("DIRE lifecycle trace #{trace.name}: #{d} has no record yet")

  defp name_of!(trace, uid),
    do:
      Map.get(trace.names, uid) || flunk("DIRE lifecycle trace #{trace.name}: unnamed uid #{uid}")

  # ---------------------------------------------------------------------------------------
  # Database reads

  @device_read_limit 1000

  # Every device the world can have produced (named, owning a world identifier, or holding a
  # world address), its merge_audit rows, and the owner of each world identifier.
  defp raw(trace) do
    devices =
      trace
      |> read_devices()
      |> Enum.reject(&MapSet.member?(trace.pre_uids, &1.uid))
      |> Map.new(fn d ->
        {d.uid,
         %{
           deleted_at: d.deleted_at,
           deleted_reason: d.deleted_reason,
           ip: d.ip,
           identity_revision: d.identity_revision
         }}
      end)

    uids = Enum.uniq(Map.keys(devices) ++ Map.keys(trace.names))

    audit =
      MergeAudit
      |> Ash.Query.filter(from_device_id in ^uids or to_device_id in ^uids)
      |> Ash.read!(actor: trace.actor)
      |> Map.new(fn a ->
        {a.event_id,
         %{
           event_id: a.event_id,
           from_device_id: a.from_device_id,
           to_device_id: a.to_device_id,
           reason: a.reason,
           details: a.details
         }}
      end)

    %{devices: devices, owners: owners(trace), audit: audit}
  end

  defp read_devices(trace) do
    uids = Enum.uniq(Map.keys(trace.names) ++ identifier_owner_uids(trace))
    ips = Map.values(trace.real.ip)

    devices =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^uids or ip in ^ips)
      |> Ash.read!(actor: trace.actor, page: [limit: @device_read_limit])
      |> Page.unwrap!()

    if length(devices) >= @device_read_limit,
      do:
        flunk(
          "DIRE lifecycle trace #{trace.name}: device read reached #{@device_read_limit} rows"
        )

    devices
  end

  # Each world identifier's owner. A source identifier is two rows (armis_device_id and its
  # integration_id); both must agree.
  defp owners(trace) do
    Map.new(trace.real.ids, fn {i, real} ->
      uids =
        real
        |> identifier_rows()
        |> Enum.map(fn {type, value} -> owner_uid(trace, type, value) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case uids do
        [] -> {i, nil}
        [uid] -> {i, uid}
        many -> flunk("DIRE lifecycle trace #{trace.name}: #{i} owned by #{inspect(many)}")
      end
    end)
  end

  defp identifier_owner_uids(trace) do
    values =
      trace.real.ids
      |> Map.values()
      |> Enum.flat_map(&identifier_rows/1)
      |> Enum.map(&elem(&1, 1))

    DeviceIdentifier
    |> Ash.Query.filter(identifier_value in ^values)
    |> Ash.read!(actor: trace.actor)
    |> Enum.map(& &1.device_id)
  end

  defp owner_uid(trace, type, value) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == ^type and identifier_value == ^value)
    |> Ash.read!(actor: trace.actor)
    |> case do
      [] ->
        nil

      [%{device_id: uid}] ->
        uid

      many ->
        flunk("DIRE lifecycle trace #{trace.name}: #{type} #{value} has #{length(many)} rows")
    end
  end

  defp identifier_rows({:src, v}),
    do: [{:armis_device_id, v}, {:integration_id, integration_id(v)}]

  defp identifier_rows(real), do: [identifier_key(real)]

  # The {type, value} a match or a merge row names.
  defp identifier_key({:src, v}), do: {:armis_device_id, v}
  defp identifier_key({:mac, mac}), do: {:mac, mac |> String.replace(":", "") |> String.upcase()}
  defp identifier_key({:agent, v}), do: {:agent_id, v}

  defp integration_id(value), do: "armis:source-trace:device:#{value}"

  defp hex2(n), do: n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()

  # ---------------------------------------------------------------------------------------
  # Output

  @doc """
  Compares the trace with the committed files, or writes them with DIRE_TRACE_WRITE=1.

  `demonstrates: switch` also writes `Trace_<name>__knockout.cfg`: the same trace with that
  defect switch turned off. `//formal/dire` requires TLC to reject the trace under it, which
  proves the real code exhibits the defect rather than merely being allowed to.

  `tamper: true` also emits one self-test variant per model variable, each altering that one
  variable in the final state. `//formal/dire` requires TLC to reject every variant.
  """
  def assert_golden!(trace, opts \\ []) do
    Golden.golden!(trace.name, to_tla(trace), to_cfg(trace))

    case Keyword.fetch(opts, :demonstrates) do
      {:ok, switch} ->
        switch in trace.world.bugs ||
          flunk("DIRE lifecycle trace #{trace.name}: #{switch} is not a current switch")

        knockout = %{trace | world: %{trace.world | bugs: trace.world.bugs -- [switch]}}
        Golden.golden_file!("Trace_#{trace.name}__knockout.cfg", to_cfg(knockout))

      :error ->
        :ok
    end

    if Keyword.get(opts, :tamper, false) do
      Enum.each(tampered(trace), fn {var, tampered_trace} ->
        name = "#{trace.name}__tamper_#{var}"
        Golden.golden!(name, to_tla(%{tampered_trace | name: name}), to_cfg(tampered_trace))
      end)
    end

    :ok
  end

  @variables [:status, :reason, :owner, :ipOf, :audit, :work, :act]

  defp tampered(trace) do
    {earlier, [last]} = Enum.split(trace.states, -1)

    Enum.map(@variables, fn var ->
      {var, %{trace | states: earlier ++ [Map.update!(last, var, &tamper_value(var, &1, trace))]}}
    end)
  end

  # Change exactly one entry of the variable, to another value of the same kind.
  defp tamper_value(:act, act, _trace), do: %{act | name: "Tick"}
  defp tamper_value(:work, [], trace), do: [%{target: hd(trace.world.devices), stale: false}]
  defp tamper_value(:work, _work, _trace), do: []

  defp tamper_value(:audit, [], trace) do
    d = hd(trace.world.devices)
    [%{from: d, to: d, kind: "merge", ids: [], srcIds: [], recent: true}]
  end

  defp tamper_value(:audit, [row | rest], _trace), do: [%{row | recent: not row.recent} | rest]

  defp tamper_value(var, fun, trace) when is_map(fun) do
    [key | _] = fun |> Map.keys() |> Enum.sort()
    Map.update!(fun, key, &tamper_entry(var, &1, trace))
  end

  defp tamper_entry(:status, "live", _trace), do: "tomb"
  defp tamper_entry(:status, _status, _trace), do: "live"
  defp tamper_entry(:reason, "none", _trace), do: "other"
  defp tamper_entry(:reason, _reason, _trace), do: "none"
  defp tamper_entry(:owner, "NoDev", trace), do: hd(trace.world.devices)
  defp tamper_entry(:owner, _d, _trace), do: "NoDev"
  defp tamper_entry(:ipOf, "NoIp", trace), do: hd(trace.world.ips)
  defp tamper_entry(:ipOf, _p, _trace), do: "NoIp"

  def to_tla(trace) do
    states = Enum.map_join(trace.states, ",\n", &("  " <> tla_state(&1)))

    """
    ---- MODULE Trace_#{trace.name} ----
    \\* Generated by ServiceRadar.DireLifecycleTrace from the integration test that drives this
    \\* scenario. Regenerate with DIRE_TRACE_WRITE=1; do not edit by hand.
    EXTENDS DireLifecycleTrace

    TheLog == <<
    #{states}
    >>
    ====
    """
  end

  def to_cfg(trace) do
    w = trace.world
    max_audit = trace.states |> Enum.map(&length(&1.audit)) |> Enum.max()

    """
    CONSTANTS
      Devices = #{set(w.devices)}
      Ids = #{set(Map.keys(w.ids))}
      Ips = #{set(w.ips)}
      NoDev = NoDev
      NoIp = NoIp
      Bugs = #{set(w.bugs)}
      MaxAudit = #{max(max_audit, 1)}
      MaxWork = 1
      FollowDepth = #{@follow_depth}
      TraceLog <- TheLog
    INIT TraceInit
    NEXT TraceNext
    INVARIANT TraceIncomplete
    """
  end

  defp tla_state(s) do
    a = s.act

    "[status |-> #{fun_map(s.status, &str/1)}, " <>
      "reason |-> #{fun_map(s.reason, &str/1)}, " <>
      "owner |-> #{fun_map(s.owner, &marker/1)}, " <>
      "ipOf |-> #{fun_map(s.ipOf, &marker/1)}, " <>
      "audit |-> <<#{Enum.map_join(s.audit, ", ", &tla_row/1)}>>, " <>
      "work |-> {#{Enum.map_join(s.work, ", ", &"[target |-> #{str(&1.target)}, stale |-> #{tla_bool(&1.stale)}]")}}, " <>
      "act |-> [name |-> #{str(a.name)}, u |-> #{marker(a.u)}, v |-> #{marker(a.v)}, " <>
      "row |-> #{a.row}, stale |-> #{tla_bool(a.stale)}, bumped |-> #{set(a.bumped)}]]"
  end

  defp tla_row(r) do
    "[from |-> #{str(r.from)}, to |-> #{str(r.to)}, kind |-> #{str(r.kind)}, " <>
      "ids |-> #{set(r.ids)}, srcIds |-> #{set(r.srcIds)}, recent |-> #{tla_bool(r.recent)}]"
  end

  # Model "none" markers are model values, not strings.
  defp marker(v) when v in ["NoDev", "NoIp"], do: v
  defp marker(v), do: str(v)
end
