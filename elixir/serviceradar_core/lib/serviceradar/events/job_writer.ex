defmodule ServiceRadar.Events.JobWriter do
  @moduledoc """
  Writes internal job lifecycle events into the tenant OCSF events table.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @type severity :: :informational | :low | :medium | :high | :critical

  @type opts :: [
          tenant_id: Ecto.UUID.t(),
          job_name: String.t(),
          job_id: String.t() | nil,
          queue: String.t() | nil,
          attempt: non_neg_integer() | nil,
          max_attempts: non_neg_integer() | nil,
          error: term() | nil,
          details: map() | nil,
          message: String.t() | nil,
          severity: severity(),
          log_name: String.t() | nil,
          log_provider: String.t() | nil,
          time: DateTime.t() | nil
        ]

  @spec write_failure(opts()) :: :ok | {:error, term()}
  def write_failure(opts) do
    with {:ok, tenant_id} <- fetch_required(opts, :tenant_id),
         {:ok, job_name} <- fetch_required(opts, :job_name),
         {:ok, schema} <- resolve_schema(tenant_id) do
      attrs = build_failure_attrs(opts, tenant_id, job_name)

      OcsfEvent
      |> Ash.Changeset.for_create(:record, attrs, tenant: schema)
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, record} ->
          EventsPubSub.broadcast_event(record)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("Failed to write job failure event: #{inspect(e)}")
      {:error, e}
  end

  defp resolve_schema(tenant_id) do
    tenant_id_str = to_string(tenant_id)

    case TenantSchemas.schema_for_id(tenant_id_str) do
      nil ->
        Logger.error("Could not resolve tenant schema for tenant_id: #{tenant_id_str}")
        {:error, {:unknown_tenant, tenant_id_str}}

      schema ->
        {:ok, schema}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_required, key}}
    end
  end

  defp build_failure_attrs(opts, tenant_id, job_name) do
    job_id = Keyword.get(opts, :job_id)
    queue = Keyword.get(opts, :queue)
    attempt = Keyword.get(opts, :attempt)
    max_attempts = Keyword.get(opts, :max_attempts)
    error = Keyword.get(opts, :error)
    details = Keyword.get(opts, :details)
    log_name = Keyword.get(opts, :log_name, "jobs.oban")
    log_provider = Keyword.get(opts, :log_provider, "serviceradar.core")
    time = Keyword.get(opts, :time, DateTime.utc_now())
    severity = Keyword.get(opts, :severity, :high)
    activity_id = OCSF.activity_log_update()
    severity_id = severity_to_id(severity)
    status_id = OCSF.status_failure()

    message =
      Keyword.get(opts, :message) ||
        build_message(job_name, attempt, max_attempts)

    %{
      time: time,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message,
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: correlation_uid(job_name, job_id)
        ),
      observables: build_observables(job_name, job_id),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: job_name),
      log_name: log_name,
      log_provider: log_provider,
      log_level: severity_to_level(severity),
      unmapped:
        build_unmapped(
          job_name,
          job_id,
          queue,
          attempt,
          max_attempts,
          error,
          details
        ),
      tenant_id: tenant_id
    }
  end

  defp build_message(job_name, attempt, max_attempts) do
    attempt_part =
      if attempt && max_attempts do
        " after #{attempt}/#{max_attempts} attempts"
      else
        ""
      end

    "Job #{job_name} failed#{attempt_part}"
  end

  defp correlation_uid(job_name, nil), do: job_name
  defp correlation_uid(job_name, job_id), do: "#{job_name}:#{job_id}"

  defp build_observables(job_name, nil), do: [OCSF.build_observable(job_name, "Job Name", 99)]

  defp build_observables(job_name, job_id) do
    [
      OCSF.build_observable(job_name, "Job Name", 99),
      OCSF.build_observable(job_id, "Job ID", 99)
    ]
  end

  defp build_unmapped(job_name, job_id, queue, attempt, max_attempts, error, details) do
    base = %{
      "job_name" => job_name,
      "job_id" => job_id,
      "queue" => queue,
      "attempt" => attempt,
      "max_attempts" => max_attempts,
      "error" => maybe_string(error)
    }

    if is_map(details) and map_size(details) > 0 do
      Map.put(base, "details", stringify_keys(details))
    else
      base
    end
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_string(value) when is_binary(value), do: value
  defp maybe_string(value), do: inspect(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_keys(value), do: value

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v) do
    Atom.to_string(v)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v), do: v

  defp severity_to_id(:informational), do: OCSF.severity_informational()
  defp severity_to_id(:low), do: OCSF.severity_low()
  defp severity_to_id(:medium), do: OCSF.severity_medium()
  defp severity_to_id(:high), do: OCSF.severity_high()
  defp severity_to_id(:critical), do: OCSF.severity_critical()
  defp severity_to_id(_), do: OCSF.severity_informational()

  defp severity_to_level(:informational), do: "info"
  defp severity_to_level(:low), do: "notice"
  defp severity_to_level(:medium), do: "warning"
  defp severity_to_level(:high), do: "error"
  defp severity_to_level(:critical), do: "critical"
  defp severity_to_level(_), do: "info"
end
