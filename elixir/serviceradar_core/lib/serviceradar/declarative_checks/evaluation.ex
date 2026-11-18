defmodule ServiceRadar.DeclarativeChecks.Evaluation do
  @moduledoc """
  Scheduled and event-driven evaluation passes for `DeclarativeCheck` (`2.4`).

  Supports `singleton`, 1,000-device paged `srql_devices` fan-out (with scope
  departure pruning and `ServiceState` `"inactive"` demotion), `service_targets`
  fan-out, Hybrid Edge + Core observation loading, OCSF `health.state_change`
  emission via `VerdictEventWriter`, and `StatefulAlertRule` reconciliation.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.DeclarativeChecks.AlertRuleSync
  alias ServiceRadar.DeclarativeChecks.DAGEngine
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.DeclarativeChecks.ServiceStateProjector
  alias ServiceRadar.DeclarativeChecks.VerdictEventWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  require Ash.Query

  @page_limit 1_000
  @system_actor SystemActor.system(:declarative_check_evaluation)

  @doc """
  Executes one full evaluation pass for `check` and stamps `last_evaluated_at`
  when running against CNPG.
  """
  @spec run_full(map() | struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_full(check, opts \\ []) when is_map(check) and is_list(opts) do
    actor = Keyword.get(opts, :actor, @system_actor)
    started_at = Keyword.get_lazy(opts, :now, &db_now/0)

    with {:ok, summary} <- run(check, Keyword.put(opts, :now, started_at)),
         :ok <- maybe_record_pass(check, actor, opts) do
      {:ok, summary}
    end
  end

  @doc """
  Executes one evaluation pass over `check`'s target binding without moving
  schedule marks.
  """
  @spec run(map() | struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(check, opts \\ []) when is_map(check) and is_list(opts) do
    topology =
      SchemaValidator.classify_topology(Map.get(check, :nodes) || Map.get(check, "nodes") || [])

    if topology == :edge_only and not Keyword.get(opts, :force_edge_eval?, false) do
      {:ok, %{evaluated: 0, transitions: [], removed: 0, topology: :edge_only}}
    else
      started_at = Keyword.get(opts, :now, DateTime.utc_now())

      binding =
        Map.get(check, :target_binding) || Map.get(check, "target_binding") ||
          %{"mode" => "singleton"}

      mode = Map.get(binding, "mode") || Map.get(binding, :mode) || "singleton"

      with {:ok, evaluated, transitions, removed} <-
             run_for_mode(mode, check, binding, started_at, opts) do
        if Keyword.get(opts, :emit_events?, true) do
          VerdictEventWriter.write_transitions(check, transitions, opts)
        end

        if Keyword.get(opts, :reconcile_alert_rule?, false) do
          _ = AlertRuleSync.reconcile(check, opts)
        end

        {:ok,
         %{
           evaluated: evaluated,
           transitions: transitions,
           removed: removed,
           topology: topology
         }}
      end
    end
  end

  defp run_for_mode("singleton", check, binding, started_at, opts) do
    target_ctx = %{
      "target_key" => "singleton",
      "url" => Map.get(binding, "url"),
      "host" => Map.get(binding, "host"),
      "port" => Map.get(binding, "port")
    }

    edge_obs = load_edge_observations_for_targets(check, ["singleton"], opts)
    eval_opts = Keyword.merge(opts, now: started_at, edge_observations: edge_obs)

    with {:ok, eval_res} <- DAGEngine.evaluate_target(check, target_ctx, eval_opts),
         {:ok, transitions} <- persist_instances(check, [eval_res], :singleton, started_at, opts) do
      {:ok, 1, transitions, 0}
    end
  end

  defp run_for_mode("srql_devices", check, binding, started_at, opts) do
    scope_query =
      Map.get(binding, "scope_query") || Map.get(binding, :scope_query) || "in:devices"

    norm_res =
      if Keyword.has_key?(opts, :device_pages_loader) do
        {:ok, scope_query}
      else
        Scope.normalize(scope_query)
      end

    with {:ok, normalized} <- norm_res do
      scope_opts =
        opts
        |> Keyword.take([:runner])
        |> Keyword.put(:page_limit, Keyword.get(opts, :page_limit, @page_limit))

      {evaluated, transitions_rev} =
        normalized
        |> stream_device_pages(scope_opts, opts)
        |> Enum.reduce({0, []}, fn uids, {count_acc, trans_acc} ->
          rows = evaluate_device_page(check, uids, started_at, opts)
          {:ok, page_transitions} = persist_instances(check, rows, :device, started_at, opts)
          {count_acc + length(rows), [page_transitions | trans_acc]}
        end)

      removed = prune_departed_targets(check, started_at, opts)
      {:ok, evaluated, transitions_rev |> Enum.reverse() |> List.flatten(), removed}
    end
  end

  defp run_for_mode("service_targets", check, binding, started_at, opts) do
    targets = resolve_service_targets(binding, opts)

    {evaluated, transitions_rev} =
      targets
      |> Enum.chunk_every(@page_limit)
      |> Enum.reduce({0, []}, fn page, {count_acc, trans_acc} ->
        tkeys = Enum.map(page, & &1["target_key"])
        edge_obs = load_edge_observations_for_targets(check, tkeys, opts)
        eval_opts = Keyword.merge(opts, now: started_at, edge_observations: edge_obs)

        rows =
          Enum.flat_map(page, fn target_ctx ->
            case DAGEngine.evaluate_target(check, target_ctx, eval_opts) do
              {:ok, res} -> [res]
              _ -> []
            end
          end)

        {:ok, page_transitions} =
          persist_instances(check, rows, :service_target, started_at, opts)

        {count_acc + length(rows), [page_transitions | trans_acc]}
      end)

    removed = prune_departed_targets(check, started_at, opts)
    {:ok, evaluated, transitions_rev |> Enum.reverse() |> List.flatten(), removed}
  end

  defp stream_device_pages(normalized_query, scope_opts, opts) do
    case Keyword.get(opts, :device_pages_loader) do
      fun when is_function(fun, 1) -> fun.(normalized_query)
      _ -> Scope.stream_uids(normalized_query, scope_opts)
    end
  end

  defp evaluate_device_page(_check, [], _started_at, _opts), do: []

  defp evaluate_device_page(check, uids, started_at, opts) do
    live_devices = load_live_devices(uids, opts)
    live_uids = Enum.filter(uids, &Map.has_key?(live_devices, &1))

    if live_uids == [] do
      []
    else
      target_keys = Enum.map(live_uids, &"device:#{&1}")
      vantage_map = load_vantage_availability(check, live_uids, opts)
      edge_obs = load_edge_observations_for_targets(check, target_keys, opts)

      eval_opts =
        Keyword.merge(opts,
          now: started_at,
          vantage_observations: vantage_map,
          edge_observations: edge_obs
        )

      Enum.flat_map(live_uids, fn uid ->
        dev = Map.fetch!(live_devices, uid)

        target_ctx = %{
          "target_key" => "device:#{uid}",
          "uid" => uid,
          "ip" => Map.get(dev, :ip) || Map.get(dev, "ip"),
          "hostname" => Map.get(dev, :hostname) || Map.get(dev, "hostname"),
          "host" => Map.get(dev, :hostname) || Map.get(dev, :ip) || Map.get(dev, "ip"),
          "tags" => Map.get(dev, :tags) || Map.get(dev, "tags") || %{},
          "metadata" => Map.get(dev, :metadata) || Map.get(dev, "metadata") || %{}
        }

        case DAGEngine.evaluate_target(check, target_ctx, eval_opts) do
          {:ok, res} -> [res]
          _ -> []
        end
      end)
    end
  end

  defp resolve_service_targets(binding, opts) do
    case Keyword.get(opts, :service_targets_loader) do
      fun when is_function(fun, 1) ->
        fun.(binding)

      _ ->
        binding
        |> Map.get("target_ids", [])
        |> List.wrap()
        |> Enum.map(fn id ->
          %{
            "target_key" => "service:#{id}",
            "service_target_id" => to_string(id),
            "id" => to_string(id),
            "url" => Map.get(binding, "url"),
            "host" => Map.get(binding, "host"),
            "port" => Map.get(binding, "port")
          }
        end)
    end
  end

  defp persist_instances(_check, [], _target_kind, _evaluated_at, _opts), do: {:ok, []}

  defp persist_instances(check, eval_rows, target_kind, evaluated_at, opts) do
    case Keyword.get(opts, :instance_persister) do
      persister when is_function(persister, 4) ->
        persister.(check, eval_rows, target_kind, evaluated_at)

      _ ->
        persist_instances_db(check, eval_rows, target_kind, evaluated_at, opts)
    end
  end

  defp persist_instances_db(check, eval_rows, target_kind, evaluated_at, opts) do
    actor = Keyword.get(opts, :actor, @system_actor)
    check_id = Map.get(check, :id) || Map.get(check, "id")
    target_keys = Enum.map(eval_rows, & &1.target_key)
    existing = load_existing_instances(check_id, target_keys, actor)

    transitions =
      Enum.reduce(eval_rows, [], fn row, acc ->
        prior = Map.get(existing, row.target_key)
        changed? = is_nil(prior) or prior.verdict != row.verdict or prior.status != row.status
        changed_at = if changed?, do: evaluated_at, else: prior.changed_at

        attrs = %{
          check_id: check_id,
          target_key: row.target_key,
          target_kind: target_kind,
          device_uid: row.device_uid,
          service_target_id: row.service_target_id,
          verdict: row.verdict,
          status: row.status,
          summary: row.summary,
          node_snapshots: row.node_snapshots,
          evaluated_at: evaluated_at,
          changed_at: changed_at
        }

        {:ok, saved} = DeclarativeCheckInstance.upsert_instance(attrs, actor: actor)
        _ = ServiceStateProjector.project_instance(check, saved, opts)

        if changed? do
          [
            %{
              target_key: row.target_key,
              device_uid: row.device_uid,
              service_target_id: row.service_target_id,
              from_verdict: prior && prior.verdict,
              to_verdict: row.verdict,
              from_status: prior && prior.status,
              to_status: row.status,
              summary: row.summary,
              evaluated_at: evaluated_at
            }
            | acc
          ]
        else
          acc
        end
      end)

    {:ok, Enum.reverse(transitions)}
  end

  defp load_existing_instances(check_id, target_keys, actor) do
    query =
      DeclarativeCheckInstance
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(check_id == ^check_id and target_key in ^target_keys)

    case Ash.read(query, actor: actor) do
      {:ok, rows} -> Map.new(rows, &{&1.target_key, &1})
      _ -> %{}
    end
  end

  defp prune_departed_targets(check, started_at, opts) do
    case Keyword.get(opts, :instance_pruner) do
      pruner when is_function(pruner, 2) ->
        {removed_count, departed_keys} = pruner.(check, started_at)
        slug = to_string(Map.get(check, :slug) || Map.get(check, "slug"))
        ServiceStateProjector.deactivate_targets(slug, departed_keys, opts)
        removed_count

      _ ->
        check_id = Map.get(check, :id) || Map.get(check, "id")
        slug = to_string(Map.get(check, :slug) || Map.get(check, "slug"))

        departed_keys =
          DeclarativeCheckInstance
          |> where([i], i.check_id == ^check_id and i.evaluated_at < ^started_at)
          |> select([i], i.target_key)
          |> Repo.all()

        if departed_keys == [] do
          0
        else
          {count, _} =
            DeclarativeCheckInstance
            |> where([i], i.check_id == ^check_id and i.target_key in ^departed_keys)
            |> Repo.delete_all()

          ServiceStateProjector.deactivate_targets(slug, departed_keys, opts)
          count
        end
    end
  end

  defp load_live_devices(uids, opts) do
    case Keyword.get(opts, :live_devices_loader) do
      fun when is_function(fun, 1) ->
        fun.(uids)

      _ ->
        Device
        |> where([d], d.uid in ^uids and is_nil(d.deleted_at))
        |> select([d], %{
          uid: d.uid,
          ip: d.ip,
          hostname: d.hostname,
          tags: d.tags,
          metadata: d.metadata
        })
        |> Repo.all()
        |> Map.new(&{&1.uid, &1})
    end
  end

  defp load_vantage_availability(check, uids, opts) do
    case Keyword.get(opts, :vantage_observations) do
      m when is_map(m) ->
        m

      nil ->
        agent_ids =
          check
          |> Map.get(:nodes, Map.get(check, "nodes", []))
          |> Enum.filter(&((Map.get(&1, "kind") || Map.get(&1, :kind)) == "vantage_point"))
          |> Enum.map(fn n ->
            cfg = Map.get(n, "config") || Map.get(n, :config) || %{}
            Map.get(cfg, "agent_id") || Map.get(cfg, :agent_id)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        if agent_ids == [] do
          %{}
        else
          DeviceAgentAvailability
          |> where([a], a.device_uid in ^uids and a.agent_id in ^agent_ids)
          |> Repo.all()
          |> Enum.group_by(& &1.device_uid)
          |> Map.new(fn {uid, rows} -> {uid, Map.new(rows, &{&1.agent_id, &1})} end)
        end
    end
  end

  defp load_edge_observations_for_targets(check, target_keys, opts) do
    case Keyword.get(opts, :edge_observations) do
      m when is_map(m) ->
        m

      nil ->
        check_id = Map.get(check, :id) || Map.get(check, "id")

        if is_nil(check_id) or target_keys == [] or not is_pid(Process.whereis(Repo)) do
          %{}
        else
          query =
            DeclarativeCheckEdgeObservation
            |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
            |> Ash.Query.filter(check_id == ^check_id and target_key in ^target_keys)

          case Ash.read(query, actor: @system_actor) do
            {:ok, rows} ->
              Enum.reduce(rows, %{}, fn obs, acc ->
                acc
                |> Map.put({obs.node_id, obs.target_key, obs.agent_id}, obs)
                |> Map.put_new({obs.node_id, obs.target_key}, obs)
              end)

            _ ->
              %{}
          end
        end
    end
  end

  defp maybe_record_pass(%{__struct__: DeclarativeCheck} = check, actor, opts) do
    if Keyword.has_key?(opts, :instance_persister) do
      :ok
    else
      case DeclarativeCheck.record_pass(check, %{last_evaluated_at: db_now()}, actor: actor) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_record_pass(_plain_map, _actor, _opts), do: :ok

  @doc false
  def db_now do
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    DateTime.truncate(now, :microsecond)
  rescue
    _ -> DateTime.utc_now()
  end
end
