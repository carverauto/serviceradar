defmodule ServiceRadar.Infrastructure.AgentCertExpiryMonitor do
  @moduledoc """
  Periodic Oban worker that evaluates non-superseded edge agents' mTLS client
  certificate expiration timestamps (`cert_expires_at`) and manages certificate
  expiry alerts.

  ## Thresholds

  - `0 < cert_expires_at - now <= 14d` and `> 7d`: `:warning` alert (`expiry_state: "expiring_soon"`)
  - `0 < cert_expires_at - now <= 7d`: `:critical` alert (`expiry_state: "expiring_soon"`)
  - `cert_expires_at <= now`: `:critical` alert (`expiry_state: "expired"`)
  - `cert_expires_at - now > 14d`: resolves any active certificate expiry alert for that agent
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_reschedule_seconds 900
  @warning_threshold_days 14
  @critical_threshold_days 7
  @seconds_per_day 86_400
  @source_id_prefix "agent_cert_expiry:"

  @doc """
  Schedules the periodic monitor if Oban is running and no job is queued.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t() | :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    now =
      case Map.get(job.args, "now") do
        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> dt
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

    summary = evaluate(now: now)

    Logger.info(
      "AgentCertExpiryMonitor completed",
      checked: summary.checked,
      warning_count: summary.warnings,
      critical_count: summary.criticals,
      resolved_count: summary.resolved
    )

    schedule_next()
    :ok
  end

  @doc """
  Evaluates all non-superseded agents with a recorded `cert_expires_at` timestamp
  and reconciles certificate expiry alerts.
  """
  @spec evaluate(keyword()) :: %{
          checked: non_neg_integer(),
          warnings: non_neg_integer(),
          criticals: non_neg_integer(),
          resolved: non_neg_integer()
        }
  def evaluate(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = SystemActor.system(:agent_cert_expiry_monitor)

    agents =
      Repo.all(
        from(a in Agent,
          where: is_nil(a.superseded_at) and not is_nil(a.cert_expires_at)
        )
      )

    superseded_resolved = resolve_superseded_agent_alerts(actor)

    Enum.reduce(
      agents,
      %{checked: length(agents), warnings: 0, criticals: 0, resolved: superseded_resolved},
      fn agent, acc ->
        case evaluate_agent(agent, now, actor) do
          {:warning, _alert} -> %{acc | warnings: acc.warnings + 1}
          {:critical, _alert} -> %{acc | criticals: acc.criticals + 1}
          {:resolved, count} -> %{acc | resolved: acc.resolved + count}
          :noop -> acc
        end
      end
    )
  end

  @doc false
  @spec classify_expiry(DateTime.t(), DateTime.t()) ::
          {:alert, :warning | :critical, String.t(), integer()} | {:healthy, integer()}
  def classify_expiry(%DateTime{} = expires_at, %DateTime{} = now) do
    remaining_seconds = DateTime.diff(expires_at, now, :second)
    critical_seconds = @critical_threshold_days * @seconds_per_day
    warning_seconds = @warning_threshold_days * @seconds_per_day

    cond do
      remaining_seconds <= 0 ->
        {:alert, :critical, "expired", remaining_seconds}

      remaining_seconds <= critical_seconds ->
        {:alert, :critical, "expiring_soon", remaining_seconds}

      remaining_seconds <= warning_seconds ->
        {:alert, :warning, "expiring_soon", remaining_seconds}

      true ->
        {:healthy, remaining_seconds}
    end
  end

  @doc false
  @spec alert_source_id(String.t()) :: String.t()
  def alert_source_id(agent_uid) when is_binary(agent_uid), do: @source_id_prefix <> agent_uid

  defp evaluate_agent(%Agent{} = agent, %DateTime{} = now, actor) do
    case classify_expiry(agent.cert_expires_at, now) do
      {:alert, severity, expiry_state, remaining_seconds} ->
        alert =
          ensure_expiry_alert(agent, severity, expiry_state, remaining_seconds, actor)

        {severity, alert}

      {:healthy, _remaining_seconds} ->
        resolved_count = resolve_active_alerts_for_agent(agent, actor)
        if resolved_count > 0, do: {:resolved, resolved_count}, else: :noop
    end
  end

  defp ensure_expiry_alert(agent, severity, expiry_state, remaining_seconds, actor) do
    source_id = alert_source_id(agent.uid)
    active_alerts = list_active_alerts(source_id, actor)

    {matching, mismatched} =
      Enum.split_with(active_alerts, fn alert ->
        alert.severity == severity and
          Map.get(alert.metadata || %{}, "expiry_state") == expiry_state
      end)

    Enum.each(mismatched, fn stale ->
      resolve_alert(
        stale,
        "Superseded by #{severity} (#{expiry_state}) certificate expiry state",
        actor
      )
    end)

    metadata = build_alert_metadata(agent, expiry_state, remaining_seconds)
    tags = ["certificate", "agent", expiry_state]

    case matching do
      [existing | duplicates] ->
        Enum.each(duplicates, fn dup ->
          resolve_alert(dup, "Deduplicated active certificate expiry alert", actor)
        end)

        existing
        |> Ash.Changeset.for_update(:update_metadata, %{metadata: metadata, tags: tags})
        |> Ash.update(actor: actor)
        |> case do
          {:ok, updated} -> updated
          {:error, _} -> existing
        end

      [] ->
        trigger_expiry_alert(
          agent,
          severity,
          expiry_state,
          remaining_seconds,
          metadata,
          tags,
          actor
        )
    end
  end

  defp trigger_expiry_alert(
         agent,
         severity,
         expiry_state,
         remaining_seconds,
         metadata,
         tags,
         actor
       ) do
    source_id = alert_source_id(agent.uid)
    device_uid = existing_device_uid(agent.device_uid)

    attrs = %{
      title: alert_title(agent.uid, severity, expiry_state),
      description: alert_description(agent, expiry_state, remaining_seconds),
      severity: severity,
      source_type: :agent,
      source_id: source_id,
      agent_uid: agent.uid,
      device_uid: device_uid,
      metric_name: "agent_cert_remaining_seconds",
      metric_value: remaining_seconds * 1.0,
      threshold_value: threshold_seconds(severity, expiry_state) * 1.0,
      comparison: :less_than,
      metadata: metadata,
      tags: tags
    }

    case Alert
         |> Ash.Changeset.for_create(:trigger, attrs)
         |> Ash.create(actor: actor) do
      {:ok, alert} ->
        alert

      {:error, reason} ->
        Logger.warning(
          "Failed to trigger certificate expiry alert for agent #{agent.uid}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp resolve_active_alerts_for_agent(%Agent{} = agent, actor) do
    source_id = alert_source_id(agent.uid)
    active_alerts = list_active_alerts(source_id, actor)

    note =
      if agent.cert_expires_at do
        "Agent certificate renewed (expires #{DateTime.to_iso8601(agent.cert_expires_at)})"
      else
        "Agent certificate expiry cleared"
      end

    Enum.count(active_alerts, fn alert ->
      resolve_alert(alert, note, actor) == :ok
    end)
  end

  defp resolve_superseded_agent_alerts(actor) do
    superseded_uids =
      Repo.all(
        from(a in Agent,
          where: not is_nil(a.superseded_at),
          select: a.uid
        )
      )

    Enum.reduce(superseded_uids, 0, fn uid, count ->
      source_id = alert_source_id(uid)
      active_alerts = list_active_alerts(source_id, actor)

      resolved =
        Enum.count(active_alerts, fn alert ->
          resolve_alert(alert, "Agent identity superseded", actor) == :ok
        end)

      count + resolved
    end)
  end

  defp list_active_alerts(source_id, actor) do
    Alert
    |> Ash.Query.for_read(:active)
    |> Ash.Query.filter(source_id == ^source_id)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, %Ash.Page.Keyset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  defp resolve_alert(alert, note, actor) do
    alert
    |> Ash.Changeset.for_update(:resolve, %{
      resolved_by: "agent_cert_expiry_monitor",
      resolution_note: note
    })
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  defp existing_device_uid(device_uid) when is_binary(device_uid) and device_uid != "" do
    if Repo.exists?(from(d in Device, where: d.uid == ^device_uid)) do
      device_uid
    end
  end

  defp existing_device_uid(_), do: nil

  defp build_alert_metadata(agent, expiry_state, remaining_seconds) do
    %{
      "agent_uid" => agent.uid,
      "device_uid" => agent.device_uid,
      "gateway_id" => agent.gateway_id,
      "host" => agent.host,
      "cert_expires_at" => agent.cert_expires_at && DateTime.to_iso8601(agent.cert_expires_at),
      "cert_not_before" => agent.cert_not_before && DateTime.to_iso8601(agent.cert_not_before),
      "cert_serial" => agent.cert_serial,
      "cert_fingerprint_sha256" => agent.cert_fingerprint_sha256,
      "expiry_state" => expiry_state,
      "remaining_seconds" => remaining_seconds
    }
  end

  defp alert_title(agent_uid, :critical, "expired"), do: "Agent certificate expired: #{agent_uid}"

  defp alert_title(agent_uid, :critical, "expiring_soon"),
    do: "Agent certificate expiring within 7 days: #{agent_uid}"

  defp alert_title(agent_uid, :warning, _expiry_state),
    do: "Agent certificate expiring within 14 days: #{agent_uid}"

  defp alert_description(agent, "expired", _remaining_seconds) do
    expires_iso = agent.cert_expires_at && DateTime.to_iso8601(agent.cert_expires_at)

    "Edge agent #{agent.uid} mTLS certificate (serial #{agent.cert_serial || "unknown"}) " <>
      "expired at #{expires_iso || "unknown"}."
  end

  defp alert_description(agent, "expiring_soon", remaining_seconds) do
    expires_iso = agent.cert_expires_at && DateTime.to_iso8601(agent.cert_expires_at)
    days_remaining = Float.round(remaining_seconds / @seconds_per_day, 1)

    "Edge agent #{agent.uid} mTLS certificate (serial #{agent.cert_serial || "unknown"}) " <>
      "expires at #{expires_iso || "unknown"} (#{days_remaining} days remaining)."
  end

  defp threshold_seconds(:critical, "expired"), do: 0
  defp threshold_seconds(:critical, _), do: @critical_threshold_days * @seconds_per_day
  defp threshold_seconds(:warning, _), do: @warning_threshold_days * @seconds_per_day

  defp check_existing_job do
    worker_name = Oban.Worker.to_string(__MODULE__)

    Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing", "retryable"]
      ),
      prefix: ObanSupport.prefix()
    )
  end

  defp schedule_next do
    reschedule_seconds =
      :serviceradar_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:reschedule_seconds, @default_reschedule_seconds)

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: reschedule_seconds))

    :ok
  end
end
