defmodule ServiceRadar.SweepJobs.MapperPromotion do
  @moduledoc """
  Promotes eligible sweep-discovered live hosts into on-demand mapper discovery.
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.SweepGroup

  @default_cooldown_seconds 900
  @promotion_key "sweep_mapper_promotion"
  @status_dispatched "dispatched"
  @status_suppressed "suppressed"
  @status_skipped "skipped"
  @status_failed "failed"

  @type decision :: %{
          device_uid: String.t(),
          ip: String.t(),
          job: MapperJob.t() | nil,
          reason: String.t(),
          status: atom(),
          command_id: String.t() | nil,
          cooldown_until: String.t() | nil
        }

  def promote(results, device_map, sweep_group_id, sweep_agent_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    dispatcher = Keyword.get(opts, :dispatcher, &AgentCommandBus.run_mapper_job/2)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, cooldown_seconds())
    partition = sweep_group_partition(sweep_group_id, actor)

    candidates = promotion_candidates(results, device_map)

    if candidates == [] do
      %{dispatched: 0, suppressed: 0, skipped: 0, failed: 0}
    else
      devices = load_devices(candidates, actor)
      jobs = load_mapper_jobs(partition, sweep_agent_id, actor)

      decisions =
        Enum.map(candidates, fn candidate ->
          build_decision(candidate, devices, jobs, sweep_agent_id, now)
        end)

      {promotable, final_decisions} =
        Enum.split_with(decisions, fn decision -> decision.status == :promote end)

      dispatched_decisions =
        dispatch_promotions(promotable, dispatcher, actor, cooldown_seconds)

      all_decisions = final_decisions ++ dispatched_decisions
      Enum.each(all_decisions, &log_decision/1)
      Enum.each(all_decisions, &record_promotion_state(&1, devices, actor, now, cooldown_seconds))

      summarize(all_decisions)
    end
  end

  defp cooldown_seconds do
    Application.get_env(
      :serviceradar_core,
      :sweep_mapper_promotion_cooldown_seconds,
      @default_cooldown_seconds
    )
  end

  defp promotion_candidates(results, device_map) do
    results
    |> Enum.filter(&(result_available?(&1) and is_binary(extract_ip(&1))))
    |> Enum.map(fn result ->
      ip = extract_ip(result)

      %{
        ip: ip,
        device_uid: device_uid_for_ip(device_map, ip)
      }
    end)
    |> Enum.reject(&is_nil(&1.device_uid))
    |> Enum.uniq_by(fn candidate -> {candidate.device_uid, candidate.ip} end)
  end

  defp load_devices(candidates, actor) do
    device_uids =
      candidates
      |> Enum.map(& &1.device_uid)
      |> Enum.uniq()

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^device_uids)
    |> Ash.read(actor: actor)
    |> Page.unwrap!()
    |> Map.new(&{&1.uid, &1})
  end

  defp load_mapper_jobs(partition, sweep_agent_id, actor) do
    MapperJob
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: sweep_agent_id, partition: partition})
    |> Ash.read(actor: actor)
    |> Page.unwrap!()
    |> Enum.filter(&mapper_job_eligible?/1)
    |> Enum.sort_by(&job_rank(&1, sweep_agent_id))
  end

  defp mapper_job_eligible?(job) do
    job.discovery_mode in [:snmp, :snmp_api] and job.discovery_type != :topology
  end

  defp job_rank(job, sweep_agent_id) do
    {
      agent_rank(job, sweep_agent_id),
      discovery_type_rank(job.discovery_type),
      discovery_mode_rank(job.discovery_mode),
      job.name
    }
  end

  defp agent_rank(%{agent_id: agent_id}, sweep_agent_id)
       when is_binary(agent_id) and is_binary(sweep_agent_id) and agent_id == sweep_agent_id,
       do: 0

  defp agent_rank(%{agent_id: nil}, _sweep_agent_id), do: 1
  defp agent_rank(_, _), do: 2

  defp discovery_type_rank(:full), do: 0
  defp discovery_type_rank(:interfaces), do: 1
  defp discovery_type_rank(:basic), do: 2
  defp discovery_type_rank(_), do: 3

  defp discovery_mode_rank(:snmp), do: 0
  defp discovery_mode_rank(:snmp_api), do: 1
  defp discovery_mode_rank(_), do: 2

  defp build_decision(candidate, devices, jobs, sweep_agent_id, now) do
    device = Map.get(devices, candidate.device_uid)
    cooldown_until = current_cooldown_until(device, now)

    cond do
      device == nil ->
        %{
          device_uid: candidate.device_uid,
          ip: candidate.ip,
          job: nil,
          reason: "device_not_loaded",
          status: :skipped,
          command_id: nil,
          cooldown_until: nil
        }

      cooldown_until != nil ->
        %{
          device_uid: candidate.device_uid,
          ip: candidate.ip,
          job: nil,
          reason: "cooldown_active",
          status: :suppressed,
          command_id: nil,
          cooldown_until: cooldown_until
        }

      true ->
        case List.first(jobs) do
          nil ->
            %{
              device_uid: candidate.device_uid,
              ip: candidate.ip,
              job: nil,
              reason: "no_eligible_mapper_job",
              status: :skipped,
              command_id: nil,
              cooldown_until: nil
            }

          job ->
            %{
              device_uid: candidate.device_uid,
              ip: candidate.ip,
              job: job,
              reason: promotion_reason(job, sweep_agent_id),
              status: :promote,
              command_id: nil,
              cooldown_until: nil
            }
        end
    end
  end

  defp promotion_reason(job, sweep_agent_id)
       when is_binary(sweep_agent_id) and is_binary(job.agent_id) and
              job.agent_id == sweep_agent_id,
       do: "eligible_agent_mapper_job"

  defp promotion_reason(_job, _sweep_agent_id), do: "eligible_partition_mapper_job"

  defp current_cooldown_until(nil, _now), do: nil

  defp current_cooldown_until(device, now) do
    metadata = device.metadata || %{}

    with %{} = promotion <- metadata[@promotion_key],
         cooldown_until when is_binary(cooldown_until) <- promotion["cooldown_until"],
         {:ok, cooldown_at, _offset} <- DateTime.from_iso8601(cooldown_until) do
      if DateTime.compare(cooldown_at, now) == :gt, do: cooldown_until, else: nil
    else
      _ -> nil
    end
  end

  defp dispatch_promotions([], _dispatcher, _actor, _cooldown_seconds), do: []

  defp dispatch_promotions(promotable, dispatcher, actor, _cooldown_seconds) do
    promotable
    |> Enum.group_by(& &1.job.id)
    |> Enum.flat_map(fn {_job_id, decisions} ->
      job = decisions |> List.first() |> Map.fetch!(:job)
      seeds = decisions |> Enum.map(& &1.ip) |> Enum.uniq()

      case dispatcher.(job, actor: actor, seeds: seeds, trigger_source: "sweep") do
        {:ok, command_id} ->
          Enum.map(decisions, fn decision ->
            %{
              decision
              | status: :dispatched,
                reason: "mapper_dispatched",
                command_id: command_id,
                cooldown_until: nil
            }
          end)

        {:error, reason} ->
          Logger.warning(
            "Sweep mapper promotion dispatch failed for #{job.name}: #{inspect(reason)}"
          )

          Enum.map(decisions, fn decision ->
            %{
              decision
              | status: :failed,
                reason: "mapper_dispatch_failed",
                command_id: nil,
                cooldown_until: nil
            }
          end)
      end
    end)
  end

  defp record_promotion_state(decision, devices, actor, now, cooldown_seconds) do
    payload =
      %{
        "last_status" => status_name(decision.status),
        "last_reason" => decision.reason,
        "last_attempted_at" => DateTime.to_iso8601(now),
        "last_ip" => decision.ip
      }
      |> maybe_put("mapper_job_id", decision.job && decision.job.id)
      |> maybe_put("mapper_job_name", decision.job && decision.job.name)
      |> maybe_put("command_id", decision.command_id)
      |> maybe_put("cooldown_until", cooldown_until(decision, now, cooldown_seconds))

    case Map.get(devices, decision.device_uid) do
      %Device{} = device ->
        metadata =
          device.metadata
          |> Kernel.||(%{})
          |> Map.put(@promotion_key, payload)

        device
        |> Ash.Changeset.for_update(:update, %{metadata: metadata})
        |> Ash.update(actor: actor)

        :ok

      _ ->
        Logger.warning(
          "Failed to persist sweep mapper promotion metadata for #{decision.device_uid}: device not loaded"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Failed to persist sweep mapper promotion metadata for #{decision.device_uid}: #{inspect(error)}"
      )

      :ok
  end

  defp summarize(decisions) do
    Enum.reduce(decisions, %{dispatched: 0, suppressed: 0, skipped: 0, failed: 0}, fn decision,
                                                                                      acc ->
      case decision.status do
        :dispatched -> Map.update!(acc, :dispatched, &(&1 + 1))
        :suppressed -> Map.update!(acc, :suppressed, &(&1 + 1))
        :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
        :failed -> Map.update!(acc, :failed, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  defp status_name(:dispatched), do: @status_dispatched
  defp status_name(:suppressed), do: @status_suppressed
  defp status_name(:skipped), do: @status_skipped
  defp status_name(:failed), do: @status_failed
  defp status_name(other), do: to_string(other)

  defp cooldown_until(%{status: :dispatched}, now, cooldown_seconds),
    do: now |> DateTime.add(cooldown_seconds, :second) |> DateTime.to_iso8601()

  defp cooldown_until(
         %{status: :suppressed, cooldown_until: cooldown_until},
         _now,
         _cooldown_seconds
       ),
       do: cooldown_until

  defp cooldown_until(_decision, _now, _cooldown_seconds), do: nil

  defp sweep_group_partition(nil, _actor), do: "default"
  defp sweep_group_partition("", _actor), do: "default"

  defp sweep_group_partition(sweep_group_id, actor) do
    case Ash.get(SweepGroup, sweep_group_id, actor: actor) do
      {:ok, %SweepGroup{partition: partition}} when is_binary(partition) and partition != "" ->
        partition

      _ ->
        "default"
    end
  end

  defp extract_ip(result) when is_map(result) do
    case result["host_ip"] do
      ip when is_binary(ip) ->
        case String.trim(ip) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp result_available?(result), do: result["available"] == true

  defp device_uid_for_ip(device_map, ip) do
    case Map.get(device_map, ip) do
      %{canonical_device_id: device_uid} when is_binary(device_uid) and device_uid != "" ->
        device_uid

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_decision(%{
         status: :dispatched,
         device_uid: device_uid,
         ip: ip,
         job: job,
         command_id: command_id
       }) do
    Logger.info(
      "Sweep mapper promotion dispatched device=#{device_uid} ip=#{ip} mapper_job=#{job && job.name} command_id=#{command_id}"
    )
  end

  defp log_decision(%{status: :suppressed, device_uid: device_uid, ip: ip, reason: reason}) do
    Logger.debug(
      "Sweep mapper promotion suppressed device=#{device_uid} ip=#{ip} reason=#{reason}"
    )
  end

  defp log_decision(%{status: :skipped, device_uid: device_uid, ip: ip, reason: reason}) do
    Logger.debug("Sweep mapper promotion skipped device=#{device_uid} ip=#{ip} reason=#{reason}")
  end

  defp log_decision(%{
         status: :failed,
         device_uid: device_uid,
         ip: ip,
         reason: reason,
         job: job
       }) do
    Logger.warning(
      "Sweep mapper promotion failed device=#{device_uid} ip=#{ip} mapper_job=#{job && job.name} reason=#{reason}"
    )
  end
end
