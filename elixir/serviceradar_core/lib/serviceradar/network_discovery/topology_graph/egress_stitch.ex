defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.EgressStitch do
  @moduledoc """
  Discovers internal Internet egress devices/interfaces (Tier 1 manual operator
  designations via `InterfaceSettings` / `Device.tags` + Tier 2 automagic WAN,
  `:global` IP, router/firewall, and agent egress signals), matches them via LPM
  and direct lookup against active Dgraph `Prefix` / `ext.ASN` / `ext.Vantage`
  vertices, and persists `EGRESSES_TO` edges (`topo.ingestor = "egress_stitch_v1"`).
  """

  import Bitwise
  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Dgraph
  alias ServiceRadar.Dgraph.ExternalTopology
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Store
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  @egress_ingestor "egress_stitch_v1"
  @all_reconcile_settle_ms 1_000
  @all_reconcile_max_wait_ms 15_000
  @coalesce_key {__MODULE__, :reconcile_all_coalesce}

  @doc """
  Reconciles Internet egress Dgraph stitches for a single internal device.
  Safe and non-blocking when Dgraph is not configured.
  """
  @spec reconcile_device(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_device(device_id, opts \\ []) when is_binary(device_id) and is_list(opts) do
    trimmed = String.trim(device_id)

    if trimmed == "" or (not Keyword.get(opts, :force, false) and not Store.writable?()) do
      :ok
    else
      candidates = load_candidates_for_device(trimmed)
      do_reconcile(candidates, [trimmed], opts)
    end
  end

  @doc """
  Reconciles Internet egress Dgraph stitches across all candidate internal devices.
  """
  @spec reconcile_all(keyword()) :: :ok | {:error, term()}
  def reconcile_all(opts \\ []) when is_list(opts) do
    if not Keyword.get(opts, :force, false) and not Store.writable?() do
      :ok
    else
      candidates = load_all_candidates()
      do_reconcile(candidates, [], opts)
    end
  end

  @doc """
  Triggers a trailing-edge coalesced, non-blocking `reconcile_all/0` when a
  Horizon topology snapshot has upserted external vertices and both Dgraph and
  Repo are active.

  Rapid multi-shard snapshot bursts reset the settle timer so reconciliation
  runs after the trailing shard settles (bounded by `:max_wait_ms`), and a
  trigger arriving while reconciliation is in flight schedules one follow-up
  pass instead of being dropped.
  """
  @spec maybe_reconcile_all_async(keyword()) :: :ok
  def maybe_reconcile_all_async(opts \\ []) when is_list(opts) do
    force? = Keyword.get(opts, :force, false)

    if force? or (Store.writable?() and Process.whereis(Repo) != nil) do
      settle_ms =
        opts
        |> Keyword.get(:settle_ms, Keyword.get(opts, :debounce_ms, @all_reconcile_settle_ms))
        |> max(0)

      max_wait_ms =
        opts
        |> Keyword.get(:max_wait_ms, @all_reconcile_max_wait_ms)
        |> max(settle_ms)

      reconcile_fun = Keyword.get(opts, :reconcile_fun, &reconcile_all/0)
      ref = Keyword.get(opts, :coalesce_ref) || default_coalesce_ref()

      :atomics.add(ref, 1, 1)

      if :atomics.compare_exchange(ref, 2, 0, 1) == :ok do
        Task.start(fn ->
          run_coalesced_reconcile(ref, settle_ms, max_wait_ms, reconcile_fun)
        end)
      end
    end

    :ok
  end

  @doc """
  Pure planner producing Dgraph anchor `ExternalNodeWrite`s, `EGRESSES_TO`
  `ExternalEdgeWrite`s, covering `iface.prefixes` attachments, and
  reconciliation `keep_link_keys` from CNPG candidates and Dgraph external targets.
  """
  @spec plan_egress_stitches(map(), map(), keyword()) :: %{
          nodes: [map()],
          edges: [map()],
          prefix_attachments: [{String.t(), String.t()}],
          keep_link_keys: [String.t()]
        }
  def plan_egress_stitches(candidates, targets, opts \\ [])
      when is_map(candidates) and is_map(targets) and is_list(opts) do
    now_iso = Keyword.get(opts, :now_iso) || now_rfc3339()
    indexed_targets = index_targets(targets)

    devices = Map.get(candidates, :devices, [])
    interfaces = Map.get(candidates, :interfaces, [])
    settings = Map.get(candidates, :interface_settings, [])
    agents = Map.get(candidates, :agents, [])

    interfaces_by_device = Enum.group_by(interfaces, &get_field(&1, :device_id))

    settings_by_key =
      Map.new(settings, fn s ->
        {{get_field(s, :device_id), get_field(s, :interface_uid)}, s}
      end)

    settings_by_device = Enum.group_by(settings, &get_field(&1, :device_id))
    agents_by_device = Enum.group_by(agents, &get_field(&1, :device_uid))

    acc = %{
      nodes: %{},
      edges: %{},
      attachments: MapSet.new()
    }

    acc =
      Enum.reduce(devices, acc, fn device, state ->
        device_id = get_field(device, :uid)

        if is_binary(device_id) and device_id != "" do
          dev_ifaces = Map.get(interfaces_by_device, device_id, [])
          dev_settings = Map.get(settings_by_device, device_id, [])
          dev_agents = Map.get(agents_by_device, device_id, [])

          state
          |> plan_interface_stitches(
            device_id,
            dev_ifaces,
            settings_by_key,
            indexed_targets,
            now_iso
          )
          |> plan_orphan_manual_settings(
            device_id,
            dev_ifaces,
            dev_settings,
            indexed_targets,
            now_iso
          )
          |> plan_device_stitches(device, dev_ifaces, dev_agents, indexed_targets, now_iso)
        else
          state
        end
      end)

    edges = acc.edges |> Map.values() |> Enum.sort_by(&{&1.src_id, &1.dst_id})
    nodes = acc.nodes |> Map.values() |> Enum.sort_by(& &1.id)
    attachments = acc.attachments |> MapSet.to_list() |> Enum.sort()
    keep_link_keys = Enum.map(edges, &"EGRESSES_TO|#{&1.src_id}|#{&1.dst_id}||")

    %{
      nodes: nodes,
      edges: edges,
      prefix_attachments: attachments,
      keep_link_keys: keep_link_keys
    }
  end

  @doc false
  def do_reconcile(candidates, scoped_device_ids, opts \\ [])
      when is_map(candidates) and is_list(scoped_device_ids) and is_list(opts) do
    targets_fun =
      Keyword.get(opts, :targets_loader, fn ->
        ExternalTopology.external_egress_targets(limit: 2000)
      end)

    attach_fun =
      Keyword.get(opts, :attach_prefix_fun, fn iface_key, cidr ->
        Dgraph.attach_prefix(iface_key, cidr)
      end)

    upsert_device_fun =
      Keyword.get(opts, :upsert_device_fun, fn device ->
        Dgraph.upsert_device(device)
      end)

    upsert_fun =
      Keyword.get(opts, :upsert_fun, fn snap ->
        ExternalTopology.upsert_external_topology(snap)
      end)

    reconcile_fun =
      Keyword.get(opts, :reconcile_fun, fn dev_ids, keys ->
        ExternalTopology.reconcile_egress_edges(dev_ids, keys)
      end)

    with {:ok, targets} <- targets_fun.() do
      plan = plan_egress_stitches(candidates, targets, opts)

      Enum.each(plan.prefix_attachments, fn {iface_key, cidr} ->
        _ = attach_fun.(iface_key, cidr)
      end)

      upsert_result =
        with :ok <- upsert_egress_devices(candidates, plan.edges, upsert_device_fun) do
          if plan.edges == [] and plan.nodes == [] do
            {:ok, %{nodes_upserted: 0, edges_upserted: 0, edges_skipped: 0}}
          else
            upsert_fun.(%{
              generated_at: Keyword.get(opts, :now_iso) || now_rfc3339(),
              ttl_secs: 900,
              nodes: plan.nodes,
              edges: plan.edges
            })
          end
        end

      with {:ok, stats} <- upsert_result,
           :ok <- check_edges_skipped(stats),
           {:ok, _deleted} <- reconcile_fun.(scoped_device_ids, plan.keep_link_keys) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("EgressStitch Dgraph reconcile skipped: #{inspect(reason)}",
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp upsert_egress_devices(_candidates, [], _upsert_device_fun), do: :ok

  defp upsert_egress_devices(candidates, edges, upsert_device_fun) do
    devices_by_uid =
      candidates
      |> Map.get(:devices, [])
      |> Map.new(&{get_field(&1, :uid), &1})

    edges
    |> Enum.map(& &1.src_id)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn src_id, :ok ->
      dev = Map.get(devices_by_uid, src_id, %{})

      device_write = %{
        id: src_id,
        hostname: non_blank(get_field(dev, :hostname)),
        ip: non_blank(get_field(dev, :ip))
      }

      case upsert_device_fun.(device_write) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_edges_skipped(stats) when is_map(stats) do
    skipped = get_field(stats, :edges_skipped) || 0

    if is_integer(skipped) and skipped > 0 do
      {:error, {:egress_edges_skipped, skipped}}
    else
      :ok
    end
  end

  defp check_edges_skipped(_stats), do: :ok

  defp plan_interface_stitches(state, device_id, interfaces, settings_by_key, targets, now_iso) do
    Enum.reduce(interfaces, state, fn iface, acc ->
      iface_uid = get_field(iface, :interface_uid)
      setting = Map.get(settings_by_key, {device_id, iface_uid})
      manual? = setting != nil and get_field(setting, :internet_egress) == true
      wan? = wan_interface?(iface)
      global_ips = iface |> interface_ip_candidates() |> filter_global_ips()

      if manual? or wan? or global_ips != [] do
        egress_source = if(manual?, do: "manual", else: "automagic")
        if_name = non_blank(get_field(iface, :if_name)) || non_blank(iface_uid)
        if_index = int_or_nil(get_field(iface, :if_index))
        iface_key = Utils.interface_id(device_id, get_field(iface, :if_name), if_index)

        port_speed =
          (manual? && pos_int(get_field(setting, :egress_port_speed_mbps))) ||
            speed_bps_to_mbps(get_field(iface, :speed_bps) || get_field(iface, :if_speed))

        acc =
          if manual? do
            acc
            |> add_manual_asn_target(
              device_id,
              get_field(setting, :egress_upstream_asn),
              port_speed,
              if_name,
              if_index,
              targets,
              now_iso
            )
            |> add_manual_vantage_target(
              device_id,
              get_field(setting, :egress_vantage_id),
              port_speed,
              if_name,
              if_index,
              targets,
              now_iso
            )
          else
            acc
          end

        add_ip_matches(acc, %{
          device_id: device_id,
          ips: global_ips,
          iface_key: iface_key,
          egress_source: egress_source,
          port_speed_mbps: port_speed,
          if_name: if_name,
          if_index: if_index,
          targets: targets,
          now_iso: now_iso
        })
      else
        acc
      end
    end)
  end

  defp plan_orphan_manual_settings(state, device_id, interfaces, settings, targets, now_iso) do
    known_uids = MapSet.new(interfaces, &get_field(&1, :interface_uid))

    Enum.reduce(settings, state, fn setting, acc ->
      iface_uid = get_field(setting, :interface_uid)

      if get_field(setting, :internet_egress) == true and
           not MapSet.member?(known_uids, iface_uid) do
        if_name = non_blank(iface_uid)
        port_speed = pos_int(get_field(setting, :egress_port_speed_mbps))

        acc
        |> add_manual_asn_target(
          device_id,
          get_field(setting, :egress_upstream_asn),
          port_speed,
          if_name,
          nil,
          targets,
          now_iso
        )
        |> add_manual_vantage_target(
          device_id,
          get_field(setting, :egress_vantage_id),
          port_speed,
          if_name,
          nil,
          targets,
          now_iso
        )
      else
        acc
      end
    end)
  end

  defp plan_device_stitches(state, device, interfaces, agents, targets, now_iso) do
    device_id = get_field(device, :uid)
    tags = get_field(device, :tags) || %{}
    manual_tag? = truthy_tag?(map_field(tags, "internet_egress"))
    router_or_fw? = router_or_firewall?(device)
    dev_global_ips = filter_global_ips([get_field(device, :ip)])
    agent_global_ips = agents |> Enum.map(&get_field(&1, :ip)) |> filter_global_ips()

    nat_wan? =
      router_or_fw? and Enum.any?(interfaces, &wan_interface?/1) and agent_global_ips != []

    if manual_tag? or (router_or_fw? and dev_global_ips != []) or agent_global_ips != [] or
         nat_wan? do
      egress_source = if(manual_tag?, do: "manual", else: "automagic")
      tag_speed = if(manual_tag?, do: pos_int(map_field(tags, "egress_port_speed_mbps")))

      state =
        if manual_tag? do
          state
          |> add_manual_asn_target(
            device_id,
            map_field(tags, "egress_upstream_asn"),
            tag_speed,
            nil,
            nil,
            targets,
            now_iso
          )
          |> add_manual_vantage_target(
            device_id,
            map_field(tags, "egress_vantage_id"),
            tag_speed,
            nil,
            nil,
            targets,
            now_iso
          )
        else
          state
        end

      add_ip_matches(state, %{
        device_id: device_id,
        ips: Enum.uniq(dev_global_ips ++ agent_global_ips),
        iface_key: nil,
        egress_source: egress_source,
        port_speed_mbps: tag_speed,
        if_name: nil,
        if_index: nil,
        targets: targets,
        now_iso: now_iso
      })
    else
      state
    end
  end

  defp add_manual_asn_target(
         state,
         device_id,
         raw_asn,
         port_speed,
         if_name,
         if_index,
         targets,
         now_iso
       ) do
    case pos_int(raw_asn) do
      nil ->
        state

      asn ->
        asn_id = "asn:#{asn}"

        state
        |> ensure_asn_anchor(asn_id, asn, targets, now_iso)
        |> put_egress_edge(%{
          src_id: device_id,
          dst_id: asn_id,
          kind: "egresses_to",
          border_asn: asn,
          port_speed_mbps: port_speed,
          if_name: if_name,
          if_index: if_index,
          egress_source: "manual",
          ingestor: @egress_ingestor,
          last_seen: now_iso
        })
    end
  end

  defp add_manual_vantage_target(
         state,
         device_id,
         raw_vantage,
         port_speed,
         if_name,
         if_index,
         targets,
         now_iso
       ) do
    case non_blank(raw_vantage) do
      nil ->
        state

      raw ->
        vantage_id = resolve_vantage_id(raw, targets)

        state
        |> ensure_vantage_anchor(vantage_id, targets, now_iso)
        |> put_egress_edge(%{
          src_id: device_id,
          dst_id: vantage_id,
          kind: "egresses_to",
          border_asn: nil,
          port_speed_mbps: port_speed,
          if_name: if_name,
          if_index: if_index,
          egress_source: "manual",
          ingestor: @egress_ingestor,
          last_seen: now_iso
        })
    end
  end

  defp add_ip_matches(state, %{ips: []} = _ctx), do: state

  defp add_ip_matches(state, %{ips: ips, targets: targets} = ctx) do
    Enum.reduce(ips, state, fn ip, acc ->
      acc =
        case longest_prefix_match(ip, targets.prefixes) do
          nil ->
            acc

          covering ->
            acc =
              if is_binary(ctx.iface_key) and ctx.iface_key != "" do
                %{acc | attachments: MapSet.put(acc.attachments, {ctx.iface_key, covering.cidr})}
              else
                acc
              end

            if is_integer(covering.asn) and covering.asn > 0 do
              asn_id = "asn:#{covering.asn}"

              acc
              |> ensure_asn_anchor(asn_id, covering.asn, targets, ctx.now_iso)
              |> put_egress_edge(%{
                src_id: ctx.device_id,
                dst_id: asn_id,
                kind: "egresses_to",
                border_asn: covering.asn,
                port_speed_mbps: ctx.port_speed_mbps,
                if_name: ctx.if_name,
                if_index: ctx.if_index,
                egress_source: ctx.egress_source,
                ingestor: @egress_ingestor,
                last_seen: ctx.now_iso
              })
            else
              put_egress_edge(acc, %{
                src_id: ctx.device_id,
                dst_id: covering.cidr,
                kind: "egresses_to",
                border_asn: nil,
                port_speed_mbps: ctx.port_speed_mbps,
                if_name: ctx.if_name,
                if_index: ctx.if_index,
                egress_source: ctx.egress_source,
                ingestor: @egress_ingestor,
                last_seen: ctx.now_iso
              })
            end
        end

      case Map.get(targets.vantage_by_ip, ip) do
        nil ->
          acc

        vantage ->
          put_egress_edge(acc, %{
            src_id: ctx.device_id,
            dst_id: vantage.id,
            kind: "egresses_to",
            border_asn: vantage.asn,
            port_speed_mbps: ctx.port_speed_mbps,
            if_name: ctx.if_name,
            if_index: ctx.if_index,
            egress_source: ctx.egress_source,
            ingestor: @egress_ingestor,
            last_seen: ctx.now_iso
          })
      end
    end)
  end

  defp ensure_asn_anchor(state, asn_id, asn, targets, now_iso) do
    if MapSet.member?(targets.asn_ids, asn_id) or Map.has_key?(state.nodes, asn_id) do
      state
    else
      node = %{
        id: asn_id,
        kind: "ASN",
        asn: asn,
        label: "AS#{asn}",
        ingestor: @egress_ingestor,
        last_seen: now_iso
      }

      %{state | nodes: Map.put(state.nodes, asn_id, node)}
    end
  end

  defp ensure_vantage_anchor(state, vantage_id, targets, now_iso) do
    if MapSet.member?(targets.vantage_ids, vantage_id) or Map.has_key?(state.nodes, vantage_id) do
      state
    else
      node = %{
        id: vantage_id,
        kind: "Vantage",
        label: vantage_id,
        ingestor: @egress_ingestor,
        last_seen: now_iso
      }

      %{state | nodes: Map.put(state.nodes, vantage_id, node)}
    end
  end

  defp put_egress_edge(state, edge) do
    key = {edge.src_id, edge.dst_id}

    updated =
      Map.update(state.edges, key, edge, fn prev ->
        winner =
          if egress_source_rank(edge.egress_source) >= egress_source_rank(prev.egress_source) do
            edge
          else
            prev
          end

        %{
          winner
          | port_speed_mbps: max_opt(prev.port_speed_mbps, edge.port_speed_mbps),
            if_name: winner.if_name || prev.if_name || edge.if_name,
            if_index: winner.if_index || prev.if_index || edge.if_index
        }
      end)

    %{state | edges: updated}
  end

  defp egress_source_rank("manual"), do: 2
  defp egress_source_rank("automagic"), do: 1
  defp egress_source_rank(_), do: 0

  defp max_opt(nil, b), do: b
  defp max_opt(a, nil), do: a
  defp max_opt(a, b), do: max(a, b)

  defp index_targets(targets) do
    raw_prefixes = get_field(targets, :prefixes) || []
    raw_asns = get_field(targets, :asns) || []
    raw_vantages = get_field(targets, :vantages) || []

    prefixes =
      raw_prefixes
      |> Enum.flat_map(fn pfx ->
        cidr = non_blank(get_field(pfx, :id))
        asn = pos_int(get_field(pfx, :asn))

        case parse_cidr(cidr) do
          {:ok, parsed} -> [Map.put(parsed, :asn, asn)]
          :error -> []
        end
      end)
      |> Enum.sort_by(& &1.len, :desc)

    asn_ids =
      raw_asns
      |> Enum.map(&non_blank(get_field(&1, :id)))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    vantages =
      Enum.flat_map(raw_vantages, fn v ->
        case non_blank(get_field(v, :id)) do
          nil -> []
          id -> [%{id: id, ip: clean_ip_str(get_field(v, :ip)), asn: pos_int(get_field(v, :asn))}]
        end
      end)

    vantage_ids = MapSet.new(vantages, & &1.id)

    vantage_by_ip =
      vantages
      |> Enum.reject(&is_nil(&1.ip))
      |> Map.new(&{&1.ip, &1})

    %{
      prefixes: prefixes,
      asn_ids: asn_ids,
      vantage_ids: vantage_ids,
      vantage_by_ip: vantage_by_ip
    }
  end

  defp resolve_vantage_id(raw, targets) do
    cond do
      MapSet.member?(targets.vantage_ids, raw) -> raw
      String.starts_with?(raw, "vantage:") -> raw
      MapSet.member?(targets.vantage_ids, "vantage:" <> raw) -> "vantage:" <> raw
      true -> "vantage:" <> raw
    end
  end

  defp longest_prefix_match(ip_str, prefixes) do
    case parse_ip_int(ip_str) do
      {:ok, family, ip_int, bits} ->
        Enum.find(prefixes, fn p ->
          p.family == family and
            ip_int >>> (bits - p.len) == p.net >>> (bits - p.len)
        end)

      :error ->
        nil
    end
  end

  defp parse_cidr(nil), do: :error

  defp parse_cidr(cidr) when is_binary(cidr) do
    with [ip_part, len_part] <- String.split(String.trim(cidr), "/", parts: 2),
         {len, ""} <- Integer.parse(String.trim(len_part)),
         {:ok, family, ip_int, bits} <- parse_ip_int(ip_part),
         true <- len >= 1 and len <= bits do
      all_ones = (1 <<< bits) - 1
      mask = bnot((1 <<< (bits - len)) - 1) &&& all_ones
      {:ok, %{cidr: String.trim(cidr), family: family, net: ip_int &&& mask, len: len}}
    else
      _ -> :error
    end
  end

  defp parse_ip_int(ip_str) when is_binary(ip_str) do
    clean = clean_ip_str(ip_str)

    if is_binary(clean) do
      case :inet.parse_address(String.to_charlist(clean)) do
        {:ok, {0, 0, 0, 0, 0, 0xFFFF, gh, ij}} ->
          v4 = (gh >>> 8) <<< 24 ||| (gh &&& 0xFF) <<< 16 ||| (ij >>> 8) <<< 8 ||| (ij &&& 0xFF)
          {:ok, :ipv4, v4, 32}

        {:ok, {a, b, c, d}} ->
          {:ok, :ipv4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d, 32}

        {:ok, v6} when tuple_size(v6) == 8 ->
          v6_int =
            v6
            |> Tuple.to_list()
            |> Enum.reduce(0, fn word, acc -> acc <<< 16 ||| word end)

          {:ok, :ipv6, v6_int, 128}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp parse_ip_int(_), do: :error

  defp interface_ip_candidates(iface) do
    ips =
      case get_field(iface, :ip_addresses) do
        list when is_list(list) -> list
        _ -> []
      end

    meta_cidrs =
      case get_field(iface, :metadata) do
        %{} = meta ->
          case Map.get(meta, "ip_cidrs") || Map.get(meta, :ip_cidrs) do
            str when is_binary(str) -> String.split(str, ",", trim: true)
            list when is_list(list) -> list
            _ -> []
          end

        _ ->
          []
      end

    ips ++ meta_cidrs
  end

  defp filter_global_ips(values) do
    values
    |> Enum.flat_map(fn raw ->
      case clean_ip_str(raw) do
        nil ->
          []

        ip ->
          if Address.classify(ip) == :global, do: [ip], else: []
      end
    end)
    |> Enum.uniq()
  end

  defp clean_ip_str(raw) when is_binary(raw) do
    trimmed =
      raw
      |> String.trim()
      |> String.split("/", parts: 2)
      |> hd()
      |> String.split("%", parts: 2)
      |> hd()
      |> String.trim()

    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_ip_str(_), do: nil

  defp wan_interface?(iface) do
    classifications = get_field(iface, :classifications) || []

    Enum.any?(classifications, fn c ->
      is_binary(c) and String.downcase(String.trim(c)) == "wan"
    end)
  end

  defp router_or_firewall?(device) do
    type_id = get_field(device, :type_id)
    type = device |> get_field(:type) |> to_string() |> String.downcase() |> String.trim()
    type_id in [9, 12] or type in ["router", "firewall"]
  end

  @doc false
  def device_candidate_query(device_id) when is_binary(device_id) do
    from(d in Device,
      where: d.uid == ^device_id and is_nil(d.deleted_at),
      select: %{
        uid: d.uid,
        hostname: d.hostname,
        ip: d.ip,
        type: d.type,
        type_id: d.type_id,
        tags: d.tags
      }
    )
  end

  defp load_candidates_for_device(device_id) do
    devices = Repo.all(device_candidate_query(device_id))

    interfaces =
      Repo.all(
        from(i in Interface,
          where: i.device_id == ^device_id,
          select: %{
            device_id: i.device_id,
            interface_uid: i.interface_uid,
            if_name: i.if_name,
            if_index: i.if_index,
            ip_addresses: i.ip_addresses,
            classifications: i.classifications,
            speed_bps: i.speed_bps,
            if_speed: i.if_speed,
            metadata: i.metadata
          }
        )
      )

    interface_settings =
      Repo.all(
        from(s in InterfaceSettings,
          where: s.device_id == ^device_id and s.internet_egress == true,
          select: %{
            device_id: s.device_id,
            interface_uid: s.interface_uid,
            internet_egress: s.internet_egress,
            egress_upstream_asn: s.egress_upstream_asn,
            egress_vantage_id: s.egress_vantage_id,
            egress_port_speed_mbps: s.egress_port_speed_mbps
          }
        )
      )

    agents =
      Repo.all(
        from(a in Agent,
          where: a.device_uid == ^device_id,
          select: %{device_uid: a.device_uid, ip: a.ip}
        )
      )

    %{
      devices: devices,
      interfaces: interfaces,
      interface_settings: interface_settings,
      agents: agents
    }
  end

  defp load_all_candidates do
    interface_settings =
      Repo.all(
        from(s in InterfaceSettings,
          where: s.internet_egress == true,
          select: %{
            device_id: s.device_id,
            interface_uid: s.interface_uid,
            internet_egress: s.internet_egress,
            egress_upstream_asn: s.egress_upstream_asn,
            egress_vantage_id: s.egress_vantage_id,
            egress_port_speed_mbps: s.egress_port_speed_mbps
          }
        )
      )

    interfaces =
      Repo.all(
        from(i in Interface,
          select: %{
            device_id: i.device_id,
            interface_uid: i.interface_uid,
            if_name: i.if_name,
            if_index: i.if_index,
            ip_addresses: i.ip_addresses,
            classifications: i.classifications,
            speed_bps: i.speed_bps,
            if_speed: i.if_speed,
            metadata: i.metadata
          }
        )
      )

    agents =
      Repo.all(
        from(a in Agent,
          where: not is_nil(a.device_uid),
          select: %{device_uid: a.device_uid, ip: a.ip}
        )
      )

    devices =
      Repo.all(
        from(d in Device,
          where: is_nil(d.deleted_at),
          select: %{
            uid: d.uid,
            hostname: d.hostname,
            ip: d.ip,
            type: d.type,
            type_id: d.type_id,
            tags: d.tags
          }
        )
      )

    %{
      devices: devices,
      interfaces: interfaces,
      interface_settings: interface_settings,
      agents: agents
    }
  end

  defp default_coalesce_ref do
    case :persistent_term.get(@coalesce_key, nil) do
      nil ->
        ref = :atomics.new(3, signed: false)
        :persistent_term.put(@coalesce_key, ref)
        ref

      ref ->
        ref
    end
  end

  defp run_coalesced_reconcile(ref, settle_ms, max_wait_ms, reconcile_fun) do
    completed_gen =
      try do
        coalesce_loop(ref, settle_ms, max_wait_ms, reconcile_fun)
      after
        :atomics.put(ref, 2, 0)
      end

    if is_integer(completed_gen) and :atomics.get(ref, 1) != completed_gen and
         :atomics.compare_exchange(ref, 2, 0, 1) == :ok do
      run_coalesced_reconcile(ref, settle_ms, max_wait_ms, reconcile_fun)
    end
  end

  defp coalesce_loop(ref, settle_ms, max_wait_ms, reconcile_fun) do
    started_ms = System.monotonic_time(:millisecond)
    run_gen = await_settle(ref, settle_ms, max_wait_ms, started_ms)
    :atomics.put(ref, 3, run_gen)
    _ = reconcile_fun.()

    if :atomics.get(ref, 1) == run_gen do
      run_gen
    else
      coalesce_loop(ref, settle_ms, max_wait_ms, reconcile_fun)
    end
  end

  defp await_settle(ref, settle_ms, max_wait_ms, started_ms) do
    gen_before = :atomics.get(ref, 1)
    if settle_ms > 0, do: Process.sleep(settle_ms)
    gen_after = :atomics.get(ref, 1)
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    if gen_after != gen_before and elapsed_ms < max_wait_ms do
      await_settle(ref, settle_ms, max_wait_ms, started_ms)
    else
      gen_after
    end
  end

  defp speed_bps_to_mbps(bps) when is_integer(bps) and bps >= 1_000_000, do: div(bps, 1_000_000)
  defp speed_bps_to_mbps(_), do: nil

  defp pos_int(val) when is_integer(val) and val > 0, do: val

  defp pos_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp pos_int(_), do: nil

  defp int_or_nil(val) when is_integer(val), do: val

  defp int_or_nil(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int_or_nil(_), do: nil

  defp truthy_tag?(val) when val in [true, "true", "1", "yes", "on"], do: true
  defp truthy_tag?(_), do: false

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_field(_, _), do: nil

  defp get_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get_field(_, _), do: nil

  defp non_blank(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(_), do: nil

  defp now_rfc3339 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
