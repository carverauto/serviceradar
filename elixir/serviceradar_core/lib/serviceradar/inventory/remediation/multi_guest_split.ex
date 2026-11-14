defmodule ServiceRadar.Inventory.Remediation.MultiGuestSplit do
  @moduledoc """
  Step `multi-guest-split`: splits each live record holding more than one live Proxmox v3 guest
  reference into one record per guest (OpenSpec `prevent-multi-guest-device-records`, design D5;
  requirement "Records Holding Several Hypervisor Guests Are Split On Request").

  Such a record was built at ingest, before resolution refused a second guest
  (`GuestIdentityGuard.added_guests/2`): a guest's update matched another guest's record on a MAC
  an older bad merge left there, and its reference was registered on it. Every sync of either
  guest then refreshes the same record, so it carries two machines' addresses and metadata in
  turn. There is no merge audit to undo, so the plan is computed from the record's identifiers and
  the guests' own hypervisor inventory.

  1. **Plan, at run time** (`plan/1`, pure). The record keeps the guest its linked agents and
     linked AWX memberships are proven to belong to; without such a binding, the guest whose
     reference it registered first. Bindings that point to several guests, or that no guest can be
     proven to own, leave the record whole (`ambiguous_keeper`, `unproven_binding`). Every other
     guest moves to a new record with its reference, each MAC row its NICs alone report, and each
     AWX host row whose current membership declares an address only its NICs report. Every other
     MAC or AWX row stays and is reported as unproven: ownership is never guessed, and an address
     only selects among guests the record already holds.
  2. **Split, one record at a time.** One transaction per record: lock it, plan it again on the
     locked state (`plan_changed` when the plan differs), create each guest's record, reassign its
     rows (`DeviceIdentifier :reassign_device`), record every pair of the resulting records
     distinct (`Deduplication.assert_distinct/4`) and bump every record's identity revision. Every
     planned record ends in exactly one outcome (applied, skipped with its reason, failed, or not
     run after a halt), and outcomes that do not add up fail the run
     (`unit_accounting_failures`).

  Dry run by default and explicit-only: the step is never in the default run, and its execute is
  refused unless the release runtime configuration sets `enable_multi_guest_split_execute`.
  Execute writes a synced preflight manifest entry before each transaction, one `guest_split`
  entry per new record inside it, and a committed marker after it. `source-id-rollback` reverses
  the `guest_split` entries, and `multi-guest-verify` (`MultiGuestVerification`) lists any record
  still holding several guests. The guest inventory rows are left to the next hypervisor sync,
  which binds each guest to its record through its reference.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.GuestIdentityGuard
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "multi-guest-split"
  @default_candidate_limit 5_000
  @report_limit 500
  @awx_v2 ~r/\Aawx:v2:([0-9a-f-]{36}):host:([0-9]+)\z/
  # A v3 guest reference, before `GuestIdentityGuard` parses it exactly.
  @guest_ref_pattern ":(qemu|lxc):[^:]+$"

  @doc false
  def run(mode, opts, manifest, actor) do
    data = load(opts)
    plans = Enum.map(data.devices, &plan/1)
    base = base_report(data, plans)

    case mode do
      :dry_run -> base
      :execute -> execute(data, plans, base, opts, manifest, actor)
    end
  end

  # -- loading ----------------------------------------------------------------

  @doc """
  The live records holding more than one live v3 guest reference, at most the candidate limit,
  each with what the plan reads. `:multi_guest_split_device_uids` restricts it to those records.
  """
  def load(opts) do
    limit = Keyword.get(opts, :multi_guest_split_candidate_limit, @default_candidate_limit)
    uids = candidate_uids(limit + 1)
    truncated? = length(uids) > limit

    uids =
      case Keyword.get(opts, :multi_guest_split_device_uids) do
        selected when is_list(selected) -> Enum.filter(uids, &(&1 in selected))
        _ -> Enum.take(uids, limit)
      end

    %{devices: load_devices(uids), truncated?: truncated?}
  end

  @doc "The uids of live records holding more than one live v3 guest reference, sorted."
  def candidate_uids(limit) do
    %{rows: rows} =
      query!(
        """
        SELECT di.device_id, array_agg(DISTINCT di.identifier_value)
        FROM platform.device_identifiers AS di
        JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
        WHERE di.identifier_type = 'integration_id'
          AND di.identifier_value LIKE 'proxmox:v3:%'
          AND di.identifier_value ~ $1
        GROUP BY di.device_id
        HAVING count(DISTINCT di.identifier_value) > 1
        ORDER BY di.device_id
        LIMIT $2
        """,
        [@guest_ref_pattern, limit]
      )

    for [uid, values] <- rows, length(guest_refs(values)) > 1, do: uid
  end

  defp load_devices([]), do: []

  defp load_devices(uids) do
    devices = live_devices(uids)
    rows = identifier_rows(Map.keys(devices))

    data =
      Enum.flat_map(devices, fn {uid, device} ->
        device_rows = Map.get(rows, uid, [])
        guests = device_rows |> Enum.map(& &1.value) |> guest_refs()

        if length(guests) > 1,
          do: [Map.merge(device, %{rows: device_rows, guests: guests})],
          else: []
      end)

    refs = data |> Enum.flat_map(& &1.guests) |> Enum.uniq()
    nics = guest_nics(refs)
    names = guest_names(refs)
    agents = agents(Enum.map(data, & &1.uid))
    awx = awx_memberships(Enum.flat_map(data, & &1.rows))

    data
    |> Enum.map(fn device ->
      Map.merge(device, %{
        guest_macs:
          Map.new(device.guests, &{&1, nics |> Map.get(&1, %{}) |> Map.get(:macs, MapSet.new())}),
        guest_addrs:
          Map.new(device.guests, &{&1, nics |> Map.get(&1, %{}) |> Map.get(:addrs, MapSet.new())}),
        guest_names: Map.take(names, device.guests),
        agents: Map.get(agents, device.uid, []),
        awx: Map.take(awx, for(row <- device.rows, awx_v2?(row.value), do: row.value))
      })
    end)
    |> Enum.sort_by(& &1.uid)
  end

  defp guest_refs(values),
    do: values |> Enum.filter(&GuestIdentityGuard.v3_guest_ref?/1) |> Enum.uniq() |> Enum.sort()

  defp live_devices(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT uid, hostname, partition FROM platform.ocsf_devices
        WHERE uid = ANY($1::text[]) AND deleted_at IS NULL
        """,
        [uids]
      )

    Map.new(rows, fn [uid, hostname, partition] ->
      {uid, %{uid: uid, hostname: hostname, partition: partition || "default"}}
    end)
  end

  defp identifier_rows([]), do: %{}

  defp identifier_rows(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT id, device_id, identifier_type::text, identifier_value, first_seen
        FROM platform.device_identifiers
        WHERE device_id = ANY($1::text[]) AND identifier_type IN ('mac', 'integration_id')
        ORDER BY device_id, id
        """,
        [uids]
      )

    Enum.group_by(
      rows,
      fn [_id, uid, _type, _value, _first_seen] -> uid end,
      fn [id, _uid, type, value, first_seen] ->
        %{id: id, type: type, value: value, first_seen: first_seen}
      end
    )
  end

  # The MACs and addresses each guest's NICs report, from the hypervisor inventory.
  defp guest_nics([]), do: %{}

  defp guest_nics(refs) do
    %{rows: rows} =
      query!(
        """
        SELECT guest_provider_ref, mac_address, ip_addresses::text[]
        FROM platform.virtualization_network_interfaces
        WHERE guest_provider_ref = ANY($1::text[])
        """,
        [refs]
      )

    Enum.reduce(rows, %{}, fn [ref, mac, addrs], acc ->
      macs = mac |> List.wrap() |> Enum.map(&normalize_mac/1) |> Enum.reject(&is_nil/1)
      addrs = addrs |> List.wrap() |> Enum.map(&normalize_address/1) |> Enum.reject(&is_nil/1)

      Map.update(
        acc,
        ref,
        %{macs: MapSet.new(macs), addrs: MapSet.new(addrs)},
        fn nics ->
          %{
            macs: MapSet.union(nics.macs, MapSet.new(macs)),
            addrs: MapSet.union(nics.addrs, MapSet.new(addrs))
          }
        end
      )
    end)
  end

  defp guest_names([]), do: %{}

  defp guest_names(refs) do
    %{rows: rows} =
      query!(
        "SELECT provider_ref, name FROM platform.virtualization_guests WHERE provider_ref = ANY($1::text[])",
        [refs]
      )

    for [ref, name] <- rows,
        is_binary(name) and String.trim(name) != "",
        into: %{},
        do: {ref, name}
  end

  defp agents([]), do: %{}

  defp agents(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT uid, ip, device_uid FROM platform.ocsf_agents
        WHERE device_uid = ANY($1::text[]) AND superseded_by IS NULL
        ORDER BY uid
        """,
        [uids]
      )

    Enum.group_by(rows, fn [_uid, _ip, device_uid] -> device_uid end, fn [uid, ip, _device] ->
      %{uid: uid, ip: ip}
    end)
  end

  # The current AWX memberships of each AWX v2 host row, by the row's value.
  defp awx_memberships(rows) do
    hosts =
      for %{value: value} <- rows,
          [_, controller, host] <- [Regex.run(@awx_v2, value || "")],
          uniq: true,
          do: {value, controller, String.to_integer(host)}

    case hosts do
      [] ->
        %{}

      hosts ->
        %{rows: memberships} =
          query!(
            """
            SELECT m.controller_id::text, m.awx_host_id, m.ansible_host, m.canonical_device_uid
            FROM platform.ansible_awx_host_memberships AS m
            JOIN unnest($1::text[], $2::bigint[]) AS h(controller_id, awx_host_id)
              ON h.controller_id = m.controller_id::text AND h.awx_host_id = m.awx_host_id
            WHERE m.current
            """,
            [Enum.map(hosts, &elem(&1, 1)), Enum.map(hosts, &elem(&1, 2))]
          )

        by_host =
          Enum.group_by(
            memberships,
            fn [controller, host, _ansible_host, _uid] -> {controller, host} end,
            fn [_controller, _host, ansible_host, uid] ->
              %{ansible_host: ansible_host, canonical_device_uid: uid}
            end
          )

        Map.new(hosts, fn {value, controller, host} ->
          {value, Map.get(by_host, {controller, host}, [])}
        end)
    end
  end

  defp awx_v2?(value), do: is_binary(value) and Regex.match?(@awx_v2, value)

  # -- planning ---------------------------------------------------------------

  @doc """
  The split of one record (pure): the guest that keeps it and why, the rows that move with each
  other guest, the rows no guest can be proven to own, and `status` `:split`, or `:skip` with
  `skip_reason` `ambiguous_keeper` or `unproven_binding`.
  """
  def plan(device) do
    owners = %{
      mac: &single_owner(device.guest_macs, normalize_mac(&1)),
      address: &single_owner(device.guest_addrs, normalize_address(&1))
    }

    anchors = anchors(device, owners)
    owned = Enum.map(device.rows, &{&1, row_owner(&1, device, owners)})

    base = %{
      uid: device.uid,
      guests: device.guests,
      anchors: anchors,
      unproven:
        for({row, nil} <- owned, row.type == "mac" or awx_row?(row.value), do: describe_row(row))
    }

    case keeper(device, anchors) do
      {:ok, keeper, basis} ->
        splits =
          for guest <- device.guests, guest != keeper do
            %{
              guest: guest,
              name: Map.get(device.guest_names, guest),
              rows: for({row, ^guest} <- owned, do: describe_row(row))
            }
          end

        Map.merge(base, %{status: :split, keeper: keeper, keeper_basis: basis, splits: splits})

      {:skip, reason} ->
        Map.merge(base, %{
          status: :skip,
          skip_reason: reason,
          keeper: nil,
          keeper_basis: nil,
          splits: []
        })
    end
  end

  # An agent linked to the record, and each AWX membership linked to it, names the guest whose
  # NICs alone report the address it declares.
  defp anchors(device, owners) do
    agent_anchors =
      Enum.map(device.agents, fn agent ->
        %{kind: "agent", id: agent.uid, guest: agent.ip && owners.address.(agent.ip)}
      end)

    awx_anchors =
      for {value, memberships} <- Enum.sort(device.awx),
          Enum.any?(memberships, &(&1.canonical_device_uid == device.uid)),
          do: %{kind: "awx_membership", id: value, guest: awx_owner(memberships, owners)}

    agent_anchors ++ awx_anchors
  end

  defp keeper(device, anchors) do
    case anchors |> Enum.map(& &1.guest) |> Enum.uniq() do
      [] ->
        guest =
          device.rows
          |> Enum.filter(&(&1.type == "integration_id" and &1.value in device.guests))
          |> Enum.min_by(&{sortable_time(&1.first_seen), &1.value})
          |> Map.fetch!(:value)

        {:ok, guest, "first_registered"}

      [guest] when is_binary(guest) ->
        {:ok, guest, "binding"}

      guests ->
        if nil in guests, do: {:skip, "unproven_binding"}, else: {:skip, "ambiguous_keeper"}
    end
  end

  defp row_owner(%{type: "integration_id", value: value}, device, owners) do
    cond do
      value in device.guests -> value
      awx_v2?(value) -> device.awx |> Map.get(value, []) |> awx_owner(owners)
      true -> nil
    end
  end

  defp row_owner(%{type: "mac", value: value}, _device, owners), do: owners.mac.(value)
  defp row_owner(_row, _device, _owners), do: nil

  # Every current membership of the AWX host declares an address of the same one guest.
  defp awx_owner([], _owners), do: nil

  defp awx_owner(memberships, owners) do
    case memberships
         |> Enum.map(&(&1.ansible_host && owners.address.(&1.ansible_host)))
         |> Enum.uniq() do
      [guest] when is_binary(guest) -> guest
      _ -> nil
    end
  end

  defp single_owner(_sets, nil), do: nil

  defp single_owner(sets, value) do
    case for({guest, values} <- sets, MapSet.member?(values, value), do: guest) do
      [guest] -> guest
      _none_or_several -> nil
    end
  end

  defp awx_row?(value), do: is_binary(value) and String.starts_with?(value, "awx:")

  defp describe_row(row), do: %{id: row.id, type: row.type, value: row.value}

  defp sortable_time(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)
  defp sortable_time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp sortable_time(_at), do: "~"

  defp normalize_mac(value) when is_binary(value) do
    case value |> String.upcase() |> String.replace(~r/[^0-9A-F]/, "") do
      <<_::binary-size(12)>> = mac -> mac
      _ -> nil
    end
  end

  defp normalize_mac(_value), do: nil

  defp normalize_address(value) when is_binary(value) do
    host = value |> String.trim() |> String.split("/", parts: 2) |> hd()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address |> :inet.ntoa() |> to_string()
      {:error, _} -> nil
    end
  end

  defp normalize_address(_value), do: nil

  # What execute compares under the lock: the plan must be the same split of the same rows.
  defp signature(plan) do
    {plan.status, plan.keeper,
     Enum.map(plan.splits, &{&1.guest, &1.rows |> Enum.map(fn row -> row.id end) |> Enum.sort()})}
  end

  # -- report -----------------------------------------------------------------

  defp base_report(data, plans) do
    {split, skipped} = Enum.split_with(plans, &(&1.status == :split))

    %{
      candidates: length(plans),
      candidate_limit_reached: data.truncated?,
      planned_splits: length(split),
      planned_new_records: split |> Enum.map(&length(&1.splits)) |> Enum.sum(),
      planned_rows_moved:
        split |> Enum.flat_map(& &1.splits) |> Enum.map(&length(&1.rows)) |> Enum.sum(),
      planned_skips: Enum.frequencies_by(skipped, & &1.skip_reason),
      unproven_rows: plans |> Enum.map(&length(&1.unproven)) |> Enum.sum(),
      plans: plans |> Enum.take(@report_limit) |> Enum.map(&report_plan/1)
    }
  end

  defp report_plan(plan) do
    %{
      device_uid: plan.uid,
      status: plan.status,
      skip_reason: Map.get(plan, :skip_reason),
      guests: plan.guests,
      keeper: plan.keeper,
      keeper_basis: plan.keeper_basis,
      anchors: plan.anchors,
      splits: Enum.map(plan.splits, &Map.take(&1, [:guest, :name, :rows])),
      unproven: plan.unproven
    }
  end

  # -- execute ----------------------------------------------------------------

  defp execute(data, plans, base, opts, manifest, actor) do
    cond do
      not execute_enabled?(opts) ->
        blocked(base, :multi_guest_split_execute_disabled)

      data.truncated? and not is_list(Keyword.get(opts, :multi_guest_split_device_uids)) ->
        blocked(base, :candidate_limit_reached)

      Manifest.ensure_writable(manifest) != :ok ->
        Map.merge(base, %{manifest_failures: 1, halted: "manifest"})

      true ->
        run = %{manifest: manifest, actor: actor, manifest_errors: :counters.new(1, [])}

        state =
          plans
          |> run_units(initial_state(), run)
          |> check_unit_accounting(length(plans))

        base
        |> Map.merge(state)
        |> Map.put(:execution_blocked, false)
        |> then(&if(&1.halted, do: &1, else: Map.delete(&1, :halted)))
    end
  end

  defp initial_state do
    %{
      units_applied: 0,
      records_created: 0,
      rows_moved: 0,
      distinct_asserted: 0,
      units_skipped: %{},
      skipped_units: [],
      unit_failures: 0,
      units_not_run: 0,
      unit_accounting_failures: 0,
      manifest_failures: 0,
      halted: nil
    }
  end

  defp blocked(base, reason) do
    Map.merge(base, %{
      execution_blocked: true,
      execution_blocked_reason: to_string(reason),
      records_created: 0,
      rows_moved: 0
    })
  end

  defp execute_enabled?(opts) do
    runtime? =
      :serviceradar_core
      |> Application.get_env(ServiceRadar.Inventory.Remediation.DireRemediation, [])
      |> Keyword.get(:enable_multi_guest_split_execute, false)

    runtime? and Keyword.get(opts, :multi_guest_split_execute_enabled, false)
  end

  # Each planned record ends in exactly one outcome: applied, skipped (with its reason), failed,
  # or not run because an earlier record halted the step.
  defp run_units([], state, _run), do: state

  defp run_units([plan | rest], state, run) do
    case split_unit(plan, state, run) do
      {:cont, state} -> run_units(rest, state, run)
      {:halt, state} -> %{state | units_not_run: length(rest)}
    end
  end

  defp check_unit_accounting(state, planned) do
    skipped = state.units_skipped |> Map.values() |> Enum.sum()
    accounted = state.units_applied + skipped + state.unit_failures + state.units_not_run

    if accounted == planned do
      state
    else
      Logger.error(
        "#{@step}: #{planned} record(s) planned but #{accounted} accounted for " <>
          "(applied #{state.units_applied}, skipped #{skipped}, failed #{state.unit_failures}, " <>
          "not run #{state.units_not_run})"
      )

      %{state | unit_accounting_failures: 1}
    end
  end

  defp split_unit(%{status: :skip} = plan, state, _run),
    do: {:cont, skip(state, plan.uid, plan.skip_reason)}

  defp split_unit(plan, state, run) do
    token = Ecto.UUID.generate()

    preflight =
      Manifest.record(
        run.manifest,
        @step,
        :candidate_preflight,
        "platform.ocsf_devices",
        [plan.uid],
        %{
          phase: "preflight",
          candidate_token: token,
          keeper: plan.keeper,
          guests: plan.guests
        }
      )

    with :ok <- preflight,
         {:ok, done} <- safely(fn -> unit_transaction(plan, token, run) end) do
      committed(state, run, plan.uid, token, done)
    else
      {:error, {:refused, reason}} ->
        {:cont, skip(state, plan.uid, to_string(reason))}

      {:error, reason} ->
        Logger.warning("#{@step}: split of #{plan.uid} failed: #{inspect(reason)}")
        failure(state, run, preflight)
    end
  end

  defp failure(state, run, preflight) do
    state = %{state | unit_failures: state.unit_failures + 1}

    if preflight != :ok or :counters.get(run.manifest_errors, 1) > 0 do
      {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    else
      {:cont, state}
    end
  end

  defp committed(state, run, uid, token, done) do
    state = %{
      state
      | units_applied: state.units_applied + 1,
        records_created: state.records_created + done.records_created,
        rows_moved: state.rows_moved + done.rows_moved,
        distinct_asserted: state.distinct_asserted + done.distinct_asserted
    }

    case Manifest.record(
           run.manifest,
           @step,
           :candidate_committed,
           "platform.ocsf_devices",
           [uid],
           %{phase: "committed", candidate_token: token}
         ) do
      :ok ->
        {:cont, state}

      {:error, reason} ->
        Logger.error("#{@step}: #{uid} committed but its marker failed: #{inspect(reason)}")
        {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    end
  end

  defp skip(state, uid, reason) do
    Logger.warning("#{@step}: #{uid} not split: #{reason}")

    %{
      state
      | units_skipped: Map.update(state.units_skipped, reason, 1, &(&1 + 1)),
        skipped_units: state.skipped_units ++ [%{device_uid: uid, reason: reason}]
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  # One transaction per record: lock it, plan it again on the locked state, create the guests'
  # records, move their rows, assert every pair distinct, bump every revision, and write the
  # action entries before commit. Any refusal rolls the whole record back.
  defp unit_transaction(plan, token, run) do
    Repo.transaction(
      fn ->
        lock_device(plan.uid)
        fresh = replan(plan)

        created =
          Enum.map(fresh.splits, fn split ->
            new_uid = create_guest_record(plan.uid, split, run.actor)
            reassign(split.rows, plan.uid, new_uid, run.actor)
            {split, new_uid}
          end)

        new_uids = Enum.map(created, &elem(&1, 1))
        assertions = assert_pairs([plan.uid | new_uids], run.actor)
        Enum.each([plan.uid | new_uids], &bump_revision(&1, run.actor))

        entries =
          Enum.map(created, fn {split, new_uid} ->
            %{
              action: :guest_split,
              table: "platform.ocsf_devices",
              ids: [new_uid],
              extra: %{
                phase: "prepared",
                candidate_token: token,
                device_uid: plan.uid,
                new_device_uid: new_uid,
                guest_ref: split.guest,
                keeper: fresh.keeper,
                identifier_ids: Enum.map(split.rows, & &1.id),
                identifier_values: Enum.map(split.rows, & &1.value),
                distinct_assertion_ids: Map.get(assertions, new_uid, [])
              }
            }
          end)

        case Manifest.record_batch(run.manifest, @step, entries) do
          :ok ->
            %{
              records_created: length(created),
              rows_moved: created |> Enum.map(&length(elem(&1, 0).rows)) |> Enum.sum(),
              distinct_asserted: assertions |> Map.values() |> List.flatten() |> length()
            }

          {:error, reason} ->
            :counters.add(run.manifest_errors, 1, 1)
            Repo.rollback({:manifest_prepare_failed, reason})
        end
      end,
      timeout: :infinity
    )
  end

  defp lock_device(uid) do
    query!(
      "SELECT uid FROM platform.ocsf_devices WHERE uid = $1 AND deleted_at IS NULL FOR NO KEY UPDATE",
      [uid]
    )
  end

  defp replan(plan) do
    case load_devices([plan.uid]) do
      [device] ->
        fresh = plan(device)

        cond do
          fresh.status == :skip -> Repo.rollback({:refused, fresh.skip_reason})
          signature(fresh) != signature(plan) -> Repo.rollback({:refused, :plan_changed})
          true -> fresh
        end

      [] ->
        Repo.rollback({:refused, :no_longer_multi_guest})
    end
  end

  # A uid derived from the record and the guest, so a replay of the same split plans the same
  # record; stepped past any row that already holds it, a rolled-back split's tombstone among them.
  defp create_guest_record(uid, split, actor) do
    new_uid = free_uid(Ids.reseeded_device_id("#{uid}:guest-split:#{split.guest}"), 8)
    {:ok, source} = Device.get_by_uid(uid, false, actor: actor)

    params =
      maybe_put_hostname(
        %{
          uid: new_uid,
          partition: source.partition,
          metadata: %{
            "integration_id" => split.guest,
            "integration_type" => "hypervisor",
            "device_role" => "virtual-guest",
            "hypervisor_provider" => "proxmox",
            "hypervisor_provider_ref" => split.guest,
            "split_from_device_uid" => uid
          }
        },
        split.name || source.hostname
      )

    case Device
         |> Ash.Changeset.for_create(:create, params)
         |> Ash.create(actor: actor) do
      {:ok, created} -> created.uid
      {:error, error} -> Repo.rollback({:create_failed, split.guest, error})
    end
  end

  defp free_uid(uid, 0), do: Repo.rollback({:refused, {:split_uid_taken, uid}})

  defp free_uid(uid, attempts) do
    case query!("SELECT 1 FROM platform.ocsf_devices WHERE uid = $1", [uid]) do
      %{rows: []} -> uid
      _ -> free_uid(Ids.reseeded_device_id(uid), attempts - 1)
    end
  end

  defp maybe_put_hostname(params, hostname) when is_binary(hostname) do
    if String.trim(hostname) == "", do: params, else: Map.put(params, :hostname, hostname)
  end

  defp maybe_put_hostname(params, _hostname), do: params

  defp reassign(rows, from_uid, to_uid, actor) do
    ids = Enum.map(rows, & &1.id)

    identifiers =
      DeviceIdentifier
      |> Ash.Query.filter(id in ^ids and device_id == ^from_uid)
      |> Ash.read!(actor: actor)

    if length(identifiers) != length(ids), do: Repo.rollback({:refused, :plan_changed})

    Enum.each(identifiers, fn identifier ->
      case identifier
           |> Ash.Changeset.for_update(:reassign_device, %{device_id: to_uid})
           |> Ash.update(actor: actor) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback({:reassign_failed, identifier.id, error})
      end
    end)
  end

  # Every pair of the resulting records, keyed by the newer record of the pair so that each
  # `guest_split` entry carries the assertions its rollback removes. An assertion that already
  # existed is not the step's to roll back.
  defp assert_pairs([keeper | new_uids], actor) do
    new_uids
    |> Enum.with_index()
    |> Map.new(fn {new_uid, index} ->
      partners = [keeper | Enum.take(new_uids, index)]

      ids =
        for partner <- partners, not Deduplication.asserted_distinct?(partner, new_uid) do
          case Deduplication.assert_distinct(
                 partner,
                 new_uid,
                 "#{@step}: different hypervisor guests split from #{keeper}",
                 actor
               ) do
            {:ok, assertion} -> assertion.id
            {:error, error} -> Repo.rollback({:assert_distinct_failed, new_uid, error})
          end
        end

      {new_uid, ids}
    end)
  end

  defp bump_revision(uid, actor) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(uid, false, actor: actor),
         {:ok, _} <- Device.bump_identity_revision(device, actor: actor) do
      :ok
    else
      other -> Repo.rollback({:identity_revision_bump_failed, uid, other})
    end
  end

  # -- rollback ---------------------------------------------------------------

  @doc """
  Reverse one `guest_split` manifest entry, for `source-id-rollback`: remove the distinct
  assertions the split created for its new record, then merge the new record back into the
  record it was split from (reason `manual_guest_split_rollback`), which returns every
  identifier the new record holds. Returns `{:ok, :remerged}`, or `{:ok, {:skipped, reason}}`
  when either record is no longer live. Runs inside the caller's transaction.
  """
  @spec rollback_split(map(), term()) ::
          {:ok, :remerged | {:skipped, :record_changed}} | {:error, term()}
  def rollback_split(entry, actor) do
    from = entry["new_device_uid"]
    to = entry["device_uid"]

    %{rows: live} =
      query!(
        """
        SELECT uid FROM platform.ocsf_devices
        WHERE uid = ANY($1::text[]) AND deleted_at IS NULL
        ORDER BY uid FOR NO KEY UPDATE
        """,
        [Enum.sort([from, to])]
      )

    if length(live) == 2 do
      _ =
        query!(
          "DELETE FROM platform.identity_distinct_assertions WHERE id::text = ANY($1::text[])",
          [Enum.map(entry["distinct_assertion_ids"] || [], &to_string/1)]
        )

      case MergeEngine.merge_devices(from, to,
             actor: actor,
             reason: "manual_guest_split_rollback",
             details: %{"rollback_of" => @step, "guest_ref" => entry["guest_ref"]}
           ) do
        :ok -> {:ok, :remerged}
        {:error, reason} -> {:error, {:remerge_failed, from, reason}}
      end
    else
      {:ok, {:skipped, :record_changed}}
    end
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
