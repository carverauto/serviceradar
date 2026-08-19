defmodule ServiceRadar.CompositeChecks.Validation.Orchestrator do
  @moduledoc """
  Creates validation runs, dispatches targeted vantage-point probes using
  covering sweep-group settings, and evaluates the named composite check.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.Validation.Coverage
  alias ServiceRadar.CompositeChecks.ValidationRun
  alias ServiceRadar.CompositeChecks.ValidationRunDevice
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.Identity.ResolveByAddress
  alias ServiceRadar.Scans.ScanResult
  alias ServiceRadar.Scans.ScanRun
  alias ServiceRadar.SweepJobs.ObanSupport

  @max_devices 128
  @deadline_seconds 180
  @default_partition "default"

  @spec start(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def start(params, opts \\ []) when is_map(params) do
    actor = Keyword.get(opts, :actor) || system_actor()

    with {:ok, check} <- fetch_enabled_check(params, actor),
         {:ok, targets} <- parse_targets(params),
         {:ok, resolved} <- resolve_all(targets, actor) do
      create_run(check, resolved, params, actor, opts)
    end
  end

  @spec advance(String.t() | struct(), keyword()) ::
          {:ok, :completed | :continue | :timed_out | :failed} | {:error, term()}
  def advance(run_or_id, opts \\ []) do
    actor = Keyword.get(opts, :actor) || system_actor()

    with {:ok, run} <- fetch_run(run_or_id, actor) do
      cond do
        run.status in [:completed, :failed, :timed_out] ->
          {:ok, run.status}

        deadline_passed?(run) ->
          finish(run, :timed_out, "deadline exceeded", actor)
          {:ok, :timed_out}

        run.status == :pending ->
          dispatch_probes(run, actor, opts)

        run.status == :probing ->
          collect_and_evaluate(run, actor, opts)

        run.status == :evaluating ->
          evaluate_and_finish(run, actor)

        true ->
          {:ok, :continue}
      end
    end
  end

  defp fetch_enabled_check(params, actor) do
    slug = params["check"] || params[:check]

    if not is_binary(slug) or slug == "" do
      {:error, :check_required}
    else
      case CompositeCheck.get_by_slug(slug, actor: actor) do
        {:ok, %{state: :enabled} = check} -> {:ok, check}
        {:ok, _check} -> {:error, :check_not_enabled}
        {:error, _} -> {:error, :check_not_found}
      end
    end
  end

  defp parse_targets(params) do
    default_partition =
      params["partition"] || params[:partition] || @default_partition

    cond do
      is_list(params["devices"]) or is_list(params[:devices]) ->
        (params["devices"] || params[:devices])
        |> Enum.map(&normalize_target(&1, default_partition))
        |> finalize_targets()

      is_binary(params["ip"] || params[:ip]) ->
        finalize_targets([normalize_target(params, default_partition)])

      true ->
        {:error, :empty_devices}
    end
  end

  defp normalize_target(target, default_partition) when is_map(target) do
    %{
      ip: target["ip"] || target[:ip],
      mac: target["mac"] || target[:mac],
      partition: target["partition"] || target[:partition] || default_partition
    }
  end

  defp finalize_targets(targets) do
    targets = Enum.reject(targets, fn t -> t.ip in [nil, ""] end)

    cond do
      targets == [] -> {:error, :empty_devices}
      length(targets) > @max_devices -> {:error, :too_many_devices}
      true -> {:ok, targets}
    end
  end

  defp resolve_all(targets, actor) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case ResolveByAddress.resolve(Map.put(target, :actor, actor)) do
        {:ok, uid} -> {:cont, {:ok, acc ++ [Map.put(target, :device_uid, uid)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_run(check, resolved, params, actor, opts) do
    deadline =
      opts
      |> Keyword.get(:deadline_at, DateTime.add(DateTime.utc_now(), @deadline_seconds, :second))
      |> DateTime.truncate(:microsecond)

    requested_by = params["requested_by"] || params[:requested_by]

    case ValidationRun
         |> Ash.Changeset.for_create(
           :create,
           %{
             check_id: check.id,
             check_slug: check.slug,
             deadline_at: deadline,
             requested_by: requested_by
           },
           actor: actor
         )
         |> Ash.create() do
      {:ok, run} ->
        case insert_devices(run, check, resolved, actor) do
          :ok ->
            if Keyword.get(opts, :enqueue?, true) != false do
              enqueue(run.id)
            end

            ValidationRun.get_by_id(run.id, actor: actor)

          {:error, reason} ->
            _ = Ash.destroy(run, actor: actor)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_devices(run, check, resolved, actor) do
    {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: actor)
    vantage_agents = vantage_agent_ids(inputs)

    Enum.reduce_while(resolved, :ok, fn target, :ok ->
      coverage = coverage_map(target, vantage_agents, actor)

      result =
        ValidationRunDevice
        |> Ash.Changeset.for_create(
          :create,
          %{
            run_id: run.id,
            ip: target.ip,
            partition: target.partition || @default_partition,
            mac: target.mac,
            device_uid: target.device_uid,
            coverage: coverage
          },
          actor: actor
        )
        |> Ash.create()

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp coverage_map(target, vantage_agents, actor) do
    Map.new(vantage_agents, fn agent_id ->
      case Coverage.cover(target.device_uid, target.ip, target.partition, agent_id, actor: actor) do
        {:ok, settings} ->
          modes = settings.modes || []

          if scan_modes(modes) == [] do
            {agent_id,
             %{
               "state" => "skipped",
               "reason" => "no_supported_modes",
               "modes" => modes,
               "ports" => settings.ports,
               "sweep_group_ids" => Enum.map(settings.sweep_group_ids, &to_string/1),
               "profile_ids" => Enum.map(settings.profile_ids, &to_string/1)
             }}
          else
            {agent_id,
             %{
               "state" => "pending",
               "modes" => modes,
               "ports" => settings.ports,
               "timeout_ms" => settings.timeout_ms,
               "sweep_group_ids" => Enum.map(settings.sweep_group_ids, &to_string/1),
               "profile_ids" => Enum.map(settings.profile_ids, &to_string/1)
             }}
          end

        {:error, :uncovered} ->
          {agent_id, %{"state" => "uncovered"}}
      end
    end)
  end

  defp vantage_agent_ids(inputs) do
    inputs
    |> Enum.filter(&(&1.kind == :vantage_point))
    |> Enum.map(&Map.get(&1.config, "agent_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dispatch_probes(run, actor, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, &default_dispatch/3)
    devices = run.devices || []

    plans =
      Enum.flat_map(devices, fn device ->
        device.coverage
        |> Enum.filter(fn {_agent, meta} -> coverage_get(meta, "state") == "pending" end)
        |> Enum.map(fn {agent_id, meta} -> {agent_id, device.ip, meta} end)
      end)

    grouped = Enum.group_by(plans, fn {agent_id, _ip, _meta} -> agent_id end)

    {scan_ids, errors, coverage_updates} =
      Enum.reduce(grouped, {[], [], []}, fn {agent_id, entries}, {ids, errs, updates} ->
        ips = entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        meta = merge_dispatch_meta(entries)
        modes = scan_modes(coverage_get(meta, "modes"))

        if modes == [] do
          {ids, errs, updates}
        else
          scan_opts = [
            modes: modes,
            ports: coverage_get(meta, "ports") || [],
            timeout_ms: coverage_get(meta, "timeout_ms"),
            actor: actor,
            validation_run_id: run.id
          ]

          case dispatcher.(agent_id, ips, scan_opts) do
            {:ok, scan_id} ->
              {[scan_id | ids], errs, [{agent_id, ips, scan_id} | updates]}

            {:error, reason} ->
              {ids, [reason | errs], updates}
          end
        end
      end)

    _ = mark_dispatched(run, coverage_updates, actor)

    cond do
      errors != [] and scan_ids == [] ->
        finish(run, :failed, inspect(errors), actor)
        {:ok, :failed}

      scan_ids == [] ->
        evaluate_and_finish(run, actor)

      true ->
        run
        |> Ash.Changeset.for_update(
          :update,
          %{status: :probing, scan_run_ids: Enum.reverse(scan_ids)},
          actor: actor
        )
        |> Ash.update!()

        {:ok, :continue}
    end
  end

  defp collect_and_evaluate(run, actor, _opts) do
    scans = load_scans(run.scan_run_ids, actor)

    cond do
      scans == [] ->
        evaluate_and_finish(run, actor)

      Enum.any?(scans, &(&1.status in [:pending, :running])) ->
        {:ok, :continue}

      true ->
        apply_scan_results(run, scans, actor)
        evaluate_and_finish(run, actor)
    end
  end

  defp load_scans(ids, actor) when is_list(ids) do
    Enum.flat_map(ids, fn id ->
      case ScanRun.get(id, actor: actor) do
        {:ok, scan} -> [scan]
        _ -> []
      end
    end)
  end

  defp apply_scan_results(run, scans, actor) do
    now = DateTime.utc_now()

    Enum.each(scans, fn scan ->
      results =
        case ScanResult.by_scan_run(scan.id, actor: actor) do
          {:ok, rows} -> rows
          _ -> []
        end

      available_by_ip = availability_by_ip(scan, results)
      targets = MapSet.new(List.wrap(scan.targets), &to_string/1)

      Enum.each(run.devices, fn device ->
        ip = to_string(device.ip)

        if MapSet.member?(targets, ip) do
          case Map.fetch(available_by_ip, ip) do
            {:ok, available?} ->
              upsert_availability(device.device_uid, scan.agent_id, available?, now, actor)

            :error ->
              :ok
          end
        end
      end)
    end)
  end

  # Per-target JetStream rows are authoritative. When they have not landed yet
  # (farm01's event-writer often lags the ScanRun completion payload), use
  # hosts_up: 0 => every target blocked, hosts_up == target count => every
  # target up. A partial hosts_up on a multi-target scan cannot be mapped.
  defp availability_by_ip(_scan, results) when is_list(results) and results != [] do
    results
    |> Enum.group_by(&to_string(&1.target_ip))
    |> Map.new(fn {ip, rows} -> {ip, Enum.any?(rows, & &1.available)} end)
  end

  defp availability_by_ip(scan, _empty) do
    targets = Enum.map(List.wrap(scan.targets), &to_string/1)
    hosts_up = scan.hosts_up || 0

    cond do
      targets == [] ->
        %{}

      hosts_up <= 0 ->
        Map.new(targets, &{&1, false})

      hosts_up >= length(targets) ->
        Map.new(targets, &{&1, true})

      length(targets) == 1 ->
        %{hd(targets) => true}

      true ->
        %{}
    end
  end

  defp upsert_availability(device_uid, agent_id, available?, checked_at, actor) do
    attrs = %{
      device_uid: device_uid,
      agent_id: agent_id,
      is_available: available?,
      checked_at: DateTime.truncate(checked_at, :microsecond)
    }

    case DeviceAgentAvailability.get_by_device_agent(device_uid, agent_id, actor: actor) do
      {:ok, row} ->
        row
        |> Ash.Changeset.for_update(:update, Map.drop(attrs, [:device_uid, :agent_id]),
          actor: actor
        )
        |> Ash.update()

      _ ->
        DeviceAgentAvailability
        |> Ash.Changeset.for_create(:create, attrs, actor: actor)
        |> Ash.create()
    end
  end

  defp evaluate_and_finish(run, actor) do
    run =
      run
      |> Ash.Changeset.for_update(:update, %{status: :evaluating}, actor: actor)
      |> Ash.update!()

    {:ok, check} = CompositeCheck.get_by_id(run.check_id, actor: actor)
    {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: actor)
    {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: actor)
    uids = Enum.map(run.devices, & &1.device_uid)
    now = DateTime.utc_now()

    {:ok, rows} = Evaluation.evaluate_devices(check, inputs, rules, uids, now: now)
    by_uid = Map.new(rows, &{&1.device_uid, &1})

    Enum.each(run.devices, fn device ->
      case Map.get(by_uid, device.device_uid) do
        nil ->
          :ok

        row ->
          persist_official_result(check, device, row, now, actor)

          device
          |> Ash.Changeset.for_update(
            :update,
            %{
              verdict: row.verdict,
              verdict_status: row.status,
              inputs: row.inputs,
              evaluated_at: now
            },
            actor: actor
          )
          |> Ash.update!()
      end
    end)

    finish(run, :completed, nil, actor)
    {:ok, :completed}
  end

  defp persist_official_result(check, device, row, now, actor) do
    prior =
      case DeviceCompositeCheckResult.get_by_device_check(device.device_uid, check.id,
             actor: actor
           ) do
        {:ok, existing} -> existing
        _ -> nil
      end

    changed? = is_nil(prior) or prior.verdict != row.verdict
    changed_at = if changed?, do: now, else: prior.changed_at

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: row.device_uid,
        check_id: check.id,
        verdict: row.verdict,
        status: row.status,
        matched_rule_id: row.matched_rule_id,
        inputs: row.inputs,
        evaluated_at: now,
        changed_at: changed_at
      },
      actor: actor,
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create()
  end

  defp finish(run, status, error, actor) do
    if status == :timed_out do
      mark_unfinished_devices_timed_out(run, actor)
    end

    run
    |> Ash.Changeset.for_update(:update, %{status: status, error: error}, actor: actor)
    |> Ash.update!()
  end

  defp mark_unfinished_devices_timed_out(run, actor) do
    Enum.each(run.devices || [], fn device ->
      if is_nil(device.evaluated_at) do
        device
        |> Ash.Changeset.for_update(
          :update,
          %{verdict: "inconclusive", error: "timed_out"},
          actor: actor
        )
        |> Ash.update!()
      end
    end)
  end

  defp merge_dispatch_meta(entries) do
    metas = Enum.map(entries, &elem(&1, 2))

    modes =
      metas
      |> Enum.flat_map(&List.wrap(coverage_get(&1, "modes")))
      |> Enum.uniq()

    ports =
      metas
      |> Enum.flat_map(&List.wrap(coverage_get(&1, "ports")))
      |> Enum.uniq()
      |> Enum.sort()

    timeout_ms =
      metas
      |> Enum.map(&coverage_get(&1, "timeout_ms"))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 3_000
        values -> Enum.min(values)
      end

    %{
      "modes" => modes,
      "ports" => ports,
      "timeout_ms" => timeout_ms
    }
  end

  defp mark_dispatched(_run, [], _actor), do: :ok

  defp mark_dispatched(run, updates, actor) do
    by_agent_ips =
      Map.new(updates, fn {agent_id, ips, scan_id} -> {agent_id, {MapSet.new(ips), scan_id}} end)

    Enum.each(run.devices || [], fn device ->
      coverage =
        Enum.reduce(by_agent_ips, device.coverage || %{}, fn {agent_id, {ips, scan_id}}, acc ->
          meta = acc[agent_id] || acc[to_string(agent_id)]

          if MapSet.member?(ips, device.ip) and coverage_get(meta, "state") == "pending" do
            key = if Map.has_key?(acc, agent_id), do: agent_id, else: to_string(agent_id)
            Map.put(acc, key, Map.merge(meta, %{"state" => "dispatched", "scan_id" => scan_id}))
          else
            acc
          end
        end)

      if coverage != device.coverage do
        device
        |> Ash.Changeset.for_update(:update, %{coverage: coverage}, actor: actor)
        |> Ash.update!()
      end
    end)
  end

  defp default_dispatch(agent_id, targets, opts) do
    actor = Keyword.get(opts, :actor) || system_actor()
    modes = scan_modes(Keyword.get(opts, :modes, []))
    ports = Keyword.get(opts, :ports, [])

    if modes == [] do
      {:error, :no_supported_modes}
    else
      attrs = %{
        agent_id: agent_id,
        modes: modes,
        ports: ports,
        targets: targets,
        target_count: length(targets),
        options: %{"timeout_ms" => Keyword.get(opts, :timeout_ms, 3_000)}
      }

      with {:ok, scan} <- ScanRun.create(attrs, actor: actor),
           {:ok, command_id} <-
             AgentCommandBus.dispatch_adhoc_scan(agent_id, targets,
               scan_run_id: scan.id,
               modes: modes,
               ports: ports,
               timeout_ms: Keyword.get(opts, :timeout_ms)
             ) do
        ScanRun.update_status(scan, %{scan_command_id: command_id, status: :running},
          actor: actor
        )

        {:ok, scan.id}
      end
    end
  end

  defp enqueue(run_id) do
    %{run_id: run_id}
    |> ServiceRadar.CompositeChecks.ValidationRunWorker.new()
    |> ObanSupport.safe_insert()
  end

  defp fetch_run(%ValidationRun{} = run, actor) do
    ValidationRun.get_by_id(run.id, actor: actor)
  end

  defp fetch_run(id, actor) when is_binary(id) do
    ValidationRun.get_by_id(id, actor: actor)
  end

  defp deadline_passed?(run) do
    DateTime.compare(DateTime.utc_now(), run.deadline_at) != :lt
  end

  defp coverage_get(nil, _key), do: nil

  defp coverage_get(meta, key) when is_map(meta) and is_binary(key) do
    Map.get(meta, key) || Map.get(meta, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(meta, key)
  end

  defp scan_modes(modes) do
    modes
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.flat_map(fn
      "icmp" -> [:icmp]
      "tcp" -> [:tcp]
      "tcp_connect" -> [:tcp]
      "mtr" -> [:mtr]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp system_actor, do: SystemActor.system(:validation_run)
end
