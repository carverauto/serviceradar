defmodule ServiceRadar.EventWriter.Processors.TrivyReports do
  @moduledoc """
  Processor for Trivy Operator report envelopes published by `trivy-sidecar`.

  Dual-path behavior:
  - Persist all Trivy payloads into `logs` as raw observability records.
  - Auto-promote higher-priority findings into `ocsf_events`.
  - Auto-create alerts for critical promoted events.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  import Bitwise

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.{FieldParser, OCSF}
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Observability.{LogPubSub, StatefulAlertEngine}

  require Logger

  @fallback_time DateTime.from_unix!(0)

  @severity_to_otel %{
    6 => 24,
    5 => 20,
    4 => 17,
    3 => 13,
    2 => 9,
    1 => 5,
    0 => 1
  }

  @summary_severity_keys [
    {:critical, ["criticalCount", "critical", "critical_count"]},
    {:high, ["highCount", "high", "high_count"]},
    {:medium, ["mediumCount", "medium", "medium_count"]},
    {:low, ["lowCount", "low", "low_count"]},
    {:informational, ["noneCount", "none", "none_count"]},
    {:unknown, ["unknownCount", "unknown", "unknown_count"]}
  ]

  @finding_severity_map %{
    "critical" => 5,
    "high" => 4,
    "medium" => 3,
    "low" => 2,
    "none" => 1,
    "info" => 1,
    "informational" => 1
  }

  @impl true
  def table_name, do: "logs"

  @doc false
  @spec promote_to_event?(non_neg_integer()) :: boolean()
  def promote_to_event?(severity_id), do: severity_id >= OCSF.severity_high()

  @doc false
  @spec promote_to_alert?(non_neg_integer()) :: boolean()
  def promote_to_alert?(severity_id), do: severity_id >= OCSF.severity_critical()

  @impl true
  def process_batch(messages) do
    entries =
      messages
      |> Enum.map(&parse_entry/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      {:ok, 0}
    else
      log_rows = Enum.map(entries, & &1.log_row)
      log_count = insert_log_rows(log_rows)

      report_rows = Enum.map(entries, & &1.report_row)
      report_count = upsert_report_rows(report_rows)

      finding_rows =
        entries
        |> Enum.flat_map(& &1.finding_rows)

      finding_count = upsert_finding_rows(finding_rows)

      promoted_rows =
        entries
        |> Enum.filter(fn entry -> promote_to_event?(entry.severity_id) end)
        |> Enum.map(& &1.event_row)

      {event_count, inserted_events} = insert_event_rows(promoted_rows)
      alert_count = maybe_create_priority_alerts(inserted_events)

      maybe_broadcast_logs(log_count)
      maybe_broadcast_events(event_count)
      maybe_evaluate_stateful_rules(inserted_events)

      :telemetry.execute(
        [:serviceradar, :event_writer, :trivy, :processed],
        %{
          logs_count: log_count,
          reports_count: report_count,
          findings_count: finding_count,
          events_count: event_count,
          alerts_count: alert_count
        },
        %{}
      )

      {:ok, log_count}
    end
  rescue
    e ->
      Logger.error("Trivy reports batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: _data, metadata: _metadata} = message) do
    case parse_entry(message) do
      %{event_row: event_row} -> event_row
      _ -> nil
    end
  end

  def parse_message(_), do: nil

  defp parse_entry(%{data: data, metadata: metadata}) do
    with {:ok, payload} <- decode_payload(data),
         {:ok, entry} <- build_entry(payload, metadata, data) do
      entry
    else
      {:error, reason} ->
        emit_drop(reason, metadata[:subject])
        nil
    end
  rescue
    e ->
      Logger.warning("Failed to parse Trivy report",
        reason: inspect(e),
        subject: metadata[:subject]
      )

      emit_drop(:parse_exception, metadata[:subject])
      nil
  end

  defp parse_entry(_), do: nil

  defp decode_payload(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :payload_not_map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_payload(_), do: {:error, :invalid_payload}

  defp build_entry(payload, metadata, raw_data) do
    subject = normalize_subject(metadata[:subject])
    context = build_context(payload)
    event_time = parse_event_time(payload)
    event_uuid = resolve_event_id(payload, subject, raw_data)
    log_uuid = deterministic_uuid("#{event_uuid}:log")

    severity = derive_severity(payload)
    severity_id = severity.severity_id
    status_id = severity.status_id
    severity_text = severity.log_severity

    message = event_message(payload, context, severity)

    log_row =
      build_log_row(%{
        log_uuid: log_uuid,
        payload: payload,
        subject: subject,
        metadata: metadata,
        event_time: event_time,
        severity_id: severity_id,
        severity_text: severity_text,
        message: message,
        context: context
      })

    event_row =
      build_event_row(%{
        event_uuid: event_uuid,
        log_uuid: log_uuid,
        payload: payload,
        subject: subject,
        raw_data: raw_data,
        event_time: event_time,
        severity_id: severity_id,
        status_id: status_id,
        severity_text: severity_text,
        message: message,
        context: context
      })

    report_row =
      build_report_row(%{
        event_uuid: event_uuid,
        log_uuid: log_uuid,
        payload: payload,
        event_time: event_time,
        context: context,
        severity: severity
      })

    finding_rows =
      build_finding_rows(%{
        event_uuid: event_uuid,
        payload: payload,
        event_time: event_time,
        context: context
      })

    {:ok,
     %{
       log_row: log_row,
       report_row: report_row,
       finding_rows: finding_rows,
       event_row: event_row,
       severity_id: severity_id
     }}
  end

  defp build_log_row(%{
         log_uuid: log_uuid,
         payload: payload,
         subject: subject,
         metadata: metadata,
         event_time: event_time,
         severity_id: severity_id,
         severity_text: severity_text,
         message: message,
         context: context
       }) do
    attributes =
      %{
        "trivy" => %{
          "event_id" => normalize_string(payload["event_id"]),
          "report_kind" => normalize_string(payload["report_kind"]),
          "cluster_id" => normalize_string(payload["cluster_id"]),
          "resource_version" => normalize_string(payload["resource_version"]),
          "summary" => normalize_map(payload["summary"]),
          "owner_ref" => normalize_map(payload["owner_ref"]),
          "correlation" => normalize_map(payload["correlation"])
        }
      }
      |> attach_ingest_metadata(metadata, subject)

    resource_attributes =
      %{}
      |> maybe_put("k8s.namespace.name", context["resource_namespace"])
      |> maybe_put("k8s.resource.kind", context["resource_kind"])
      |> maybe_put("k8s.resource.name", context["resource_name"])
      |> maybe_put("k8s.pod.name", context["pod_name"])
      |> maybe_put("k8s.pod.ip", context["pod_ip"])
      |> maybe_put("k8s.node.name", context["node_name"])
      |> maybe_put("host.ip", context["host_ip"])
      |> maybe_put("container.name", context["container_name"])

    %{
      id: Ecto.UUID.dump!(log_uuid),
      timestamp: event_time,
      observed_timestamp: observed_timestamp(metadata[:received_at], event_time),
      trace_id: nil,
      span_id: nil,
      trace_flags: nil,
      severity_text: severity_text,
      severity_number: Map.get(@severity_to_otel, severity_id, 1),
      body: message,
      event_name: normalize_string(payload["report_kind"]),
      source: "trivy",
      service_name: "trivy-operator",
      service_version: report_version(payload),
      service_instance: normalize_string(payload["cluster_id"]),
      scope_name: "trivy-sidecar",
      scope_version: nil,
      scope_attributes: %{"subject" => subject},
      attributes: attributes,
      resource_attributes: resource_attributes,
      created_at: DateTime.utc_now()
    }
  end

  defp build_event_row(%{
         event_uuid: event_uuid,
         log_uuid: log_uuid,
         payload: payload,
         subject: subject,
         raw_data: raw_data,
         event_time: event_time,
         severity_id: severity_id,
         status_id: status_id,
         severity_text: severity_text,
         message: message,
         context: context
       }) do
    metadata =
      build_event_metadata(payload, subject, context)
      |> Map.put("serviceradar", %{
        "source_log_id" => log_uuid,
        "promotion" => "trivy_priority_auto"
      })

    src_endpoint =
      if is_binary(context["pod_ip"]) and context["pod_ip"] != "" do
        OCSF.build_endpoint(ip: context["pod_ip"], name: context["pod_name"])
      else
        %{}
      end

    %{
      id: Ecto.UUID.dump!(event_uuid),
      time: event_time,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), OCSF.activity_log_update()),
      activity_id: OCSF.activity_log_update(),
      activity_name: OCSF.log_activity_name(OCSF.activity_log_update()),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message,
      status_id: status_id,
      status: OCSF.status_name(status_id),
      status_code: nil,
      status_detail: nil,
      metadata: metadata,
      observables: build_observables(payload, context),
      trace_id: nil,
      span_id: nil,
      actor: build_actor(payload),
      device: build_device(payload, context),
      src_endpoint: src_endpoint,
      dst_endpoint: %{},
      log_name: subject,
      log_provider: "trivy",
      log_level: severity_text,
      log_version: "1.0",
      unmapped: payload,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp build_report_row(%{
         event_uuid: event_uuid,
         log_uuid: log_uuid,
         payload: payload,
         event_time: event_time,
         context: context,
         severity: severity
       }) do
    report = normalize_map(payload["report"])
    report_payload = normalize_map(report["report"])

    summary =
      normalize_map(payload["summary"])
      |> case do
        value when map_size(value) > 0 -> value
        _ -> normalize_map(report_payload["summary"])
      end

    now = DateTime.utc_now()

    %{
      event_uuid: Ecto.UUID.dump!(event_uuid),
      observed_at: event_time,
      log_uuid: Ecto.UUID.dump!(log_uuid),
      report_kind: normalize_string(payload["report_kind"]) || "TrivyReport",
      cluster_id: normalize_string(payload["cluster_id"]),
      namespace: normalize_string(payload["namespace"]),
      name: normalize_string(payload["name"]),
      uid: normalize_string(payload["uid"]),
      resource_version: normalize_string(payload["resource_version"]),
      resource_kind: context["resource_kind"],
      resource_name: context["resource_name"],
      resource_namespace: context["resource_namespace"],
      pod_name: context["pod_name"],
      pod_namespace: context["pod_namespace"],
      pod_uid: context["pod_uid"],
      pod_ip: context["pod_ip"],
      host_ip: context["host_ip"],
      node_name: context["node_name"],
      container_name: context["container_name"],
      owner_kind: context["owner_kind"],
      owner_name: context["owner_name"],
      owner_uid: context["owner_uid"],
      severity_id: severity.severity_id,
      severity_text: severity.log_severity,
      status_id: severity.status_id,
      findings_count: severity.findings_count,
      summary: summary,
      owner_ref: normalize_map(payload["owner_ref"]),
      correlation: normalize_map(payload["correlation"]),
      report_metadata: normalize_map(report["metadata"]),
      report_payload: report_payload,
      raw_payload: payload,
      created_at: now,
      updated_at: now
    }
  end

  defp build_finding_rows(%{
         event_uuid: event_uuid,
         payload: payload,
         event_time: event_time,
         context: context
       }) do
    report_payload = normalize_map(get_in(payload, ["report", "report"]))
    event_uuid_bin = Ecto.UUID.dump!(event_uuid)
    report_kind = normalize_string(payload["report_kind"]) || "TrivyReport"
    target = report_target(report_payload, context)
    now = DateTime.utc_now()

    common =
      %{
        event_uuid: event_uuid_bin,
        observed_at: event_time,
        report_kind: report_kind,
        cluster_id: normalize_string(payload["cluster_id"]),
        namespace: normalize_string(payload["namespace"]),
        resource_name: context["resource_name"],
        pod_name: context["pod_name"],
        pod_ip: context["pod_ip"],
        target: target,
        created_at: now,
        updated_at: now
      }

    vulnerability_rows = build_vulnerability_findings(common, report_payload)
    check_rows = build_check_findings(common, report_payload)
    secret_rows = build_secret_findings(common, report_payload)

    vulnerability_rows ++ check_rows ++ secret_rows
  end

  defp build_vulnerability_findings(common, report_payload) do
    report_payload
    |> Map.get("vulnerabilities", [])
    |> normalize_list()
    |> Enum.map(fn vulnerability ->
      finding_id = pick_string(vulnerability, ["vulnerabilityID", "VulnerabilityID", "id"])
      severity_text = normalize_finding_severity(vulnerability["severity"])
      severity_id = finding_severity_id(severity_text)
      title = pick_string(vulnerability, ["title", "Title"]) || finding_id
      package_name = pick_string(vulnerability, ["pkgName", "PkgName", "packageName"])
      description = pick_string(vulnerability, ["description", "Description"])

      row =
        common
        |> Map.put(:finding_type, "vulnerability")
        |> Map.put(:finding_id, finding_id)
        |> Map.put(:title, title)
        |> Map.put(:severity_text, severity_text)
        |> Map.put(:severity_id, severity_id)
        |> Map.put(:status, pick_string(vulnerability, ["status", "Status"]) || "open")
        |> Map.put(:package_name, package_name)
        |> Map.put(
          :installed_version,
          pick_string(vulnerability, ["installedVersion", "InstalledVersion"])
        )
        |> Map.put(:fixed_version, pick_string(vulnerability, ["fixedVersion", "FixedVersion"]))
        |> Map.put(:description, description)
        |> Map.put(:references, pick_list(vulnerability, ["references", "links"]))
        |> Map.put(:raw_finding, normalize_map(vulnerability))

      Map.put(row, :fingerprint, finding_fingerprint(row))
    end)
  end

  defp build_check_findings(common, report_payload) do
    report_payload
    |> Map.get("checks", [])
    |> normalize_list()
    |> Enum.filter(&failing_check?/1)
    |> Enum.map(fn check ->
      finding_id = pick_string(check, ["checkID", "CheckID", "id"])
      severity_text = normalize_finding_severity(check["severity"])
      severity_id = finding_severity_id(severity_text)
      title = pick_string(check, ["title", "checkTitle", "name"]) || finding_id || "failed_check"

      row =
        common
        |> Map.put(:finding_type, "config_check")
        |> Map.put(:finding_id, finding_id)
        |> Map.put(:title, title)
        |> Map.put(:severity_text, severity_text)
        |> Map.put(:severity_id, severity_id)
        |> Map.put(:status, "fail")
        |> Map.put(:package_name, nil)
        |> Map.put(:installed_version, nil)
        |> Map.put(:fixed_version, nil)
        |> Map.put(:description, pick_string(check, ["description", "messages", "message"]))
        |> Map.put(:references, pick_list(check, ["references", "links"]))
        |> Map.put(:raw_finding, normalize_map(check))

      Map.put(row, :fingerprint, finding_fingerprint(row))
    end)
  end

  defp build_secret_findings(common, report_payload) do
    report_payload
    |> Map.get("secrets", [])
    |> normalize_list()
    |> Enum.map(fn secret ->
      finding_id = pick_string(secret, ["ruleID", "RuleID", "id"])
      severity_text = normalize_finding_severity(secret["severity"])
      severity_id = finding_severity_id(severity_text)
      title = pick_string(secret, ["title", "category", "rule"]) || finding_id

      row =
        common
        |> Map.put(:finding_type, "secret")
        |> Map.put(:finding_id, finding_id)
        |> Map.put(:title, title)
        |> Map.put(:severity_text, severity_text)
        |> Map.put(:severity_id, severity_id)
        |> Map.put(:status, "open")
        |> Map.put(:package_name, nil)
        |> Map.put(:installed_version, nil)
        |> Map.put(:fixed_version, nil)
        |> Map.put(:description, pick_string(secret, ["description", "match", "message"]))
        |> Map.put(:references, pick_list(secret, ["references", "links"]))
        |> Map.put(:raw_finding, normalize_map(secret))

      Map.put(row, :fingerprint, finding_fingerprint(row))
    end)
  end

  defp insert_log_rows([]), do: 0

  defp insert_log_rows(rows) do
    rows_for_insert = Enum.map(rows, &encode_text_columns/1)

    case ServiceRadar.Repo.insert_all("logs", rows_for_insert,
           on_conflict: :nothing,
           returning: false
         ) do
      {count, _} -> count
    end
  end

  defp upsert_report_rows([]), do: 0

  defp upsert_report_rows(rows) do
    rows = dedupe_rows_by_conflict_key(rows, &Map.get(&1, :event_uuid))

    updatable_columns = [
      :observed_at,
      :log_uuid,
      :report_kind,
      :cluster_id,
      :namespace,
      :name,
      :uid,
      :resource_version,
      :resource_kind,
      :resource_name,
      :resource_namespace,
      :pod_name,
      :pod_namespace,
      :pod_uid,
      :pod_ip,
      :host_ip,
      :node_name,
      :container_name,
      :owner_kind,
      :owner_name,
      :owner_uid,
      :severity_id,
      :severity_text,
      :status_id,
      :findings_count,
      :summary,
      :owner_ref,
      :correlation,
      :report_metadata,
      :report_payload,
      :raw_payload,
      :updated_at
    ]

    case ServiceRadar.Repo.insert_all("trivy_reports", rows,
           on_conflict: {:replace, updatable_columns},
           conflict_target: [:event_uuid],
           returning: false
         ) do
      {count, _} -> count
    end
  end

  defp upsert_finding_rows([]), do: 0

  defp upsert_finding_rows(rows) do
    rows = dedupe_rows_by_conflict_key(rows, &Map.get(&1, :fingerprint))

    updatable_columns = [
      :event_uuid,
      :observed_at,
      :report_kind,
      :cluster_id,
      :namespace,
      :resource_name,
      :pod_name,
      :pod_ip,
      :finding_type,
      :finding_id,
      :target,
      :title,
      :severity_text,
      :severity_id,
      :status,
      :package_name,
      :installed_version,
      :fixed_version,
      :description,
      :references,
      :raw_finding,
      :updated_at
    ]

    case ServiceRadar.Repo.insert_all("trivy_findings", rows,
           on_conflict: {:replace, updatable_columns},
           conflict_target: [:fingerprint],
           returning: false
         ) do
      {count, _} -> count
    end
  end

  defp dedupe_rows_by_conflict_key(rows, key_fun)
       when is_list(rows) and is_function(key_fun, 1) do
    {latest_by_key, ordered_keys} =
      Enum.reduce(rows, {%{}, []}, fn row, {acc, keys} ->
        key = key_fun.(row)

        keys =
          if Map.has_key?(acc, key) do
            keys
          else
            [key | keys]
          end

        {Map.put(acc, key, row), keys}
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(latest_by_key, &1))
  end

  defp insert_event_rows([]), do: {0, []}

  defp insert_event_rows(rows) do
    case ServiceRadar.Repo.insert_all("ocsf_events", rows,
           on_conflict: :nothing,
           returning: [:id]
         ) do
      {count, inserted} ->
        inserted_ids = MapSet.new(Enum.map(inserted, & &1.id))

        inserted_rows =
          rows
          |> Enum.filter(&MapSet.member?(inserted_ids, &1.id))
          |> dedupe_rows_by_conflict_key(&Map.get(&1, :id))

        {count, inserted_rows}
    end
  end

  defp maybe_create_priority_alerts(events) do
    {created, attempted} =
      Enum.reduce(events, {0, 0}, fn event, {created, attempted} ->
        maybe_create_priority_alert(event, created, attempted)
      end)

    if attempted > 0 do
      :telemetry.execute(
        [:serviceradar, :event_writer, :trivy, :alerts_created],
        %{count: created, attempted: attempted},
        %{}
      )
    end

    created
  end

  defp maybe_create_priority_alert(event, created, attempted) do
    if promote_to_alert?(event.severity_id) do
      case AlertGenerator.from_event(event, alert: alert_override(event)) do
        {:ok, %{} = _alert} ->
          {created + 1, attempted + 1}

        {:ok, :skipped} ->
          {created, attempted + 1}

        {:error, reason} ->
          Logger.warning("Failed to auto-create Trivy alert: #{inspect(reason)}")
          {created, attempted + 1}
      end
    else
      {created, attempted}
    end
  end

  defp alert_override(event) do
    resource = get_in(event, [:metadata, "resource"])
    report_kind = get_in(event, [:metadata, "report_kind"]) || "Report"
    severity = normalize_string(event.severity) || "High"

    target =
      normalize_string(resource) || normalize_string(get_in(event, [:metadata, "name"])) ||
        "resource"

    %{
      "title" => "Trivy #{severity}: #{report_kind} on #{target}",
      "description" => event.message
    }
  end

  defp maybe_broadcast_logs(0), do: :ok
  defp maybe_broadcast_logs(count), do: LogPubSub.broadcast_ingest(%{count: count})

  defp maybe_broadcast_events(0), do: :ok
  defp maybe_broadcast_events(count), do: EventsPubSub.broadcast_event(%{count: count})

  defp maybe_evaluate_stateful_rules([]), do: :ok

  defp maybe_evaluate_stateful_rules(events) do
    case StatefulAlertEngine.evaluate_events(events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Stateful alert evaluation failed for Trivy events: #{inspect(reason)}")
        :ok
    end
  end

  defp derive_severity(payload) do
    summary_counts = summary_counts(payload)

    counts =
      if count_total(summary_counts) > 0 do
        summary_counts
      else
        finding_counts(payload)
      end

    total = count_total(counts)
    severity_id = severity_id_from_counts(counts, total)
    status_id = status_id_for_severity(severity_id, total)

    %{
      severity_id: severity_id,
      status_id: status_id,
      findings_count: total,
      log_severity: severity_text_for_id(severity_id)
    }
  end

  defp summary_counts(payload) do
    summary =
      normalize_map(payload["summary"])
      |> case do
        value when map_size(value) > 0 -> value
        _ -> normalize_map(get_in(payload, ["report", "report", "summary"]))
      end

    Enum.reduce(@summary_severity_keys, empty_counts(), fn {level, keys}, acc ->
      Map.put(acc, level, count_from_any(summary, keys))
    end)
  end

  defp finding_counts(payload) do
    report = normalize_map(get_in(payload, ["report", "report"]))

    report
    |> Map.take(["checks", "vulnerabilities", "secrets"])
    |> Enum.reduce(empty_counts(), fn
      {"checks", checks}, acc when is_list(checks) ->
        Enum.reduce(checks, acc, &accumulate_check/2)

      {_kind, findings}, acc when is_list(findings) ->
        Enum.reduce(findings, acc, &accumulate_finding/2)

      {_kind, _}, acc ->
        acc
    end)
  end

  defp accumulate_check(check, acc) when is_map(check) do
    success = check["success"]

    if success in [false, "false", 0] do
      severity_level = normalize_severity_level(check["severity"])
      increment_count(acc, severity_level)
    else
      acc
    end
  end

  defp accumulate_check(_check, acc), do: acc

  defp accumulate_finding(finding, acc) when is_map(finding) do
    severity_level = normalize_severity_level(finding["severity"])
    increment_count(acc, severity_level)
  end

  defp accumulate_finding(_finding, acc), do: acc

  defp severity_id_from_counts(_counts, 0), do: OCSF.severity_informational()

  defp severity_id_from_counts(counts, _total) do
    cond do
      counts.critical > 0 -> OCSF.severity_critical()
      counts.high > 0 -> OCSF.severity_high()
      counts.medium > 0 -> OCSF.severity_medium()
      counts.low > 0 -> OCSF.severity_low()
      counts.informational > 0 -> OCSF.severity_informational()
      counts.unknown > 0 -> OCSF.severity_unknown()
      true -> OCSF.severity_informational()
    end
  end

  defp status_id_for_severity(_severity_id, 0), do: OCSF.status_success()
  defp status_id_for_severity(0, _total), do: OCSF.status_other()
  defp status_id_for_severity(_severity_id, _total), do: OCSF.status_failure()

  defp severity_text_for_id(severity_id) do
    OCSF.severity_name(severity_id)
    |> String.upcase()
  end

  defp event_message(payload, context, severity) do
    report_kind = normalize_string(payload["report_kind"]) || "TrivyReport"
    resource = resource_label(context)
    findings = severity.findings_count
    severity_text = severity.log_severity

    if findings == 0 do
      "#{report_kind} for #{resource}: no findings"
    else
      "#{report_kind} for #{resource}: #{findings} findings (#{severity_text})"
    end
  end

  defp build_event_metadata(payload, subject, context) do
    report = normalize_map(payload["report"])

    %{
      "source" => "trivy",
      "subject" => subject,
      "event_id" => normalize_string(payload["event_id"]),
      "report_kind" => normalize_string(payload["report_kind"]),
      "api_version" => normalize_string(payload["api_version"]),
      "cluster_id" => normalize_string(payload["cluster_id"]),
      "namespace" => normalize_string(payload["namespace"]),
      "name" => normalize_string(payload["name"]),
      "uid" => normalize_string(payload["uid"]),
      "resource_version" => normalize_string(payload["resource_version"]),
      "owner_ref" => normalize_map(payload["owner_ref"]),
      "summary" => normalize_map(payload["summary"]),
      "correlation" => normalize_map(payload["correlation"]),
      "resource" => resource_label(context),
      "report_metadata" => normalize_map(report["metadata"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_observables(payload, context) do
    artifact = normalize_map(get_in(payload, ["report", "report", "artifact"]))

    [
      maybe_observable(context["pod_ip"], "IP Address", 2),
      maybe_observable(context["pod_name"], "Kubernetes Pod", 99),
      maybe_observable(resource_label(context), "Resource", 99),
      maybe_observable(normalize_string(artifact["repository"]), "Image Repository", 99),
      maybe_observable(normalize_string(payload["uid"]), "Kubernetes UID", 99)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_actor(payload) do
    scanner = normalize_map(get_in(payload, ["report", "report", "scanner"]))

    OCSF.build_actor(
      app_name: normalize_string(scanner["name"]) || "trivy",
      app_ver: normalize_string(scanner["version"])
    )
  end

  defp build_device(payload, context) do
    uid =
      context["pod_uid"] ||
        normalize_string(payload["uid"]) ||
        context["resource_name"]

    OCSF.build_device(
      uid: uid,
      name: context["pod_name"] || context["resource_name"],
      hostname: context["node_name"],
      ip: context["pod_ip"]
    )
  end

  defp report_target(report_payload, context) do
    artifact = normalize_map(report_payload["artifact"])
    repository = normalize_string(artifact["repository"])
    tag = normalize_string(artifact["tag"])

    cond do
      is_binary(repository) and is_binary(tag) -> "#{repository}:#{tag}"
      is_binary(repository) -> repository
      true -> resource_label(context)
    end
  end

  defp failing_check?(check) when is_map(check) do
    check["success"] in [false, "false", 0]
  end

  defp failing_check?(_check), do: false

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp pick_string(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      map
      |> Map.get(key)
      |> normalize_string()
    end)
  end

  defp pick_string(_map, _keys), do: nil

  defp pick_list(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(map, key) do
        value when is_list(value) -> value
        _ -> nil
      end
    end)
  end

  defp pick_list(_map, _keys), do: []

  defp normalize_finding_severity(value) do
    value
    |> normalize_string()
    |> case do
      nil -> "UNKNOWN"
      text -> String.upcase(text)
    end
  end

  defp finding_severity_id(value) do
    value
    |> Kernel.||("")
    |> String.downcase()
    |> then(&Map.get(@finding_severity_map, &1, OCSF.severity_unknown()))
  end

  defp finding_fingerprint(row) do
    fingerprint_source =
      [
        row.event_uuid,
        row.finding_type,
        row.finding_id,
        row.title,
        row.package_name,
        row.target,
        row.pod_ip
      ]
      |> Enum.map_join("|", &to_string_safe/1)

    Base.encode16(:crypto.hash(:sha256, fingerprint_source), case: :lower)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp build_context(payload) do
    correlation = normalize_map(payload["correlation"])
    labels = normalize_map(get_in(payload, ["report", "metadata", "labels"]))
    owner = normalize_map(payload["owner_ref"])

    resource_kind =
      normalize_string(correlation["resource_kind"]) ||
        normalize_string(labels["trivy-operator.resource.kind"])

    resource_name =
      normalize_string(correlation["resource_name"]) ||
        normalize_string(labels["trivy-operator.resource.name"]) ||
        normalize_string(payload["name"])

    resource_namespace =
      normalize_string(correlation["resource_namespace"]) ||
        normalize_string(labels["trivy-operator.resource.namespace"]) ||
        normalize_string(payload["namespace"])

    owner_kind = normalize_string(correlation["owner_kind"]) || normalize_string(owner["kind"])
    owner_name = normalize_string(correlation["owner_name"]) || normalize_string(owner["name"])
    owner_uid = normalize_string(correlation["owner_uid"]) || normalize_string(owner["uid"])

    pod_name =
      normalize_string(correlation["pod_name"]) ||
        if is_pod?(resource_kind) do
          resource_name
        else
          if is_pod?(owner_kind), do: owner_name, else: nil
        end

    pod_namespace =
      normalize_string(correlation["pod_namespace"]) ||
        if is_binary(pod_name) and pod_name != "", do: resource_namespace, else: nil

    pod_uid =
      normalize_string(correlation["pod_uid"]) ||
        if is_pod?(owner_kind), do: owner_uid, else: nil

    %{
      "resource_kind" => resource_kind,
      "resource_name" => resource_name,
      "resource_namespace" => resource_namespace,
      "container_name" => normalize_string(correlation["container_name"]),
      "owner_kind" => owner_kind,
      "owner_name" => owner_name,
      "owner_uid" => owner_uid,
      "pod_name" => pod_name,
      "pod_namespace" => pod_namespace,
      "pod_uid" => pod_uid,
      "pod_ip" => normalize_string(correlation["pod_ip"]),
      "host_ip" => normalize_string(correlation["host_ip"]),
      "node_name" => normalize_string(correlation["node_name"])
    }
  end

  defp resource_label(context) do
    namespace = context["resource_namespace"] || "cluster"
    kind = context["resource_kind"] || "resource"
    name = context["resource_name"] || "unknown"

    "#{kind}/#{namespace}/#{name}"
  end

  defp report_version(payload) do
    payload
    |> get_in(["report", "report", "scanner", "version"])
    |> normalize_string()
  end

  defp resolve_event_id(payload, subject, raw_data) do
    event_id = normalize_string(payload["event_id"])

    cond do
      is_binary(event_id) ->
        case Ecto.UUID.cast(event_id) do
          {:ok, cast_uuid} -> cast_uuid
          :error -> deterministic_uuid("#{subject}:event_id:#{String.downcase(event_id)}")
        end

      true ->
        hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
        deterministic_uuid("#{subject}:sha256:#{hash}")
    end
  end

  defp parse_event_time(payload) do
    candidate =
      normalize_string(payload["observed_at"]) ||
        normalize_string(get_in(payload, ["report", "report", "updateTimestamp"])) ||
        normalize_string(get_in(payload, ["report", "metadata", "creationTimestamp"]))

    case candidate do
      nil ->
        @fallback_time

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          _ -> @fallback_time
        end
    end
  end

  defp observed_timestamp(%DateTime{} = received_at, _event_time), do: received_at
  defp observed_timestamp(_received_at, event_time), do: event_time

  defp normalize_subject(subject) when is_binary(subject), do: subject
  defp normalize_subject(_), do: "trivy.report.unknown"

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp is_pod?(value) when is_binary(value), do: String.downcase(value) == "pod"
  defp is_pod?(_), do: false

  defp maybe_observable(nil, _type, _type_id), do: nil
  defp maybe_observable(value, type, type_id), do: OCSF.build_observable(value, type, type_id)

  defp count_from_any(map, keys) do
    Enum.reduce_while(keys, 0, fn key, _acc ->
      case parse_count(map[key]) do
        0 -> {:cont, 0}
        value -> {:halt, value}
      end
    end)
  end

  defp parse_count(value) when is_integer(value) and value > 0, do: value
  defp parse_count(value) when is_float(value) and value > 0, do: trunc(value)

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> 0
    end
  end

  defp parse_count(_), do: 0

  defp normalize_severity_level(value) do
    normalized =
      value
      |> normalize_string()
      |> case do
        nil -> "unknown"
        text -> String.downcase(text)
      end

    case normalized do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      "none" -> :informational
      "info" -> :informational
      "informational" -> :informational
      _ -> :unknown
    end
  end

  defp increment_count(counts, key) do
    current = Map.get(counts, key, 0)
    Map.put(counts, key, current + 1)
  end

  defp count_total(counts) do
    counts.critical +
      counts.high +
      counts.medium +
      counts.low +
      counts.informational +
      counts.unknown
  end

  defp empty_counts do
    %{
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
      informational: 0,
      unknown: 0
    }
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = band(a3, 0x0FFF) |> bor(0x4000)
    versioned_a4 = band(a4, 0x3FFF) |> bor(0x8000)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a1, a2, versioned_a3, versioned_a4, a5]
    )
    |> IO.iodata_to_binary()
  end

  defp normalize_raw_data(data) when is_binary(data) do
    if String.valid?(data), do: data, else: Base.encode64(data)
  end

  defp normalize_raw_data(data), do: inspect(data)

  defp attach_ingest_metadata(attributes, metadata, subject) when is_map(attributes) do
    ingest =
      %{}
      |> maybe_put("subject", subject)
      |> maybe_put("reply_to", metadata[:reply_to])
      |> maybe_put("received_at", iso8601(metadata[:received_at]))
      |> maybe_put("source_kind", "trivy")

    if map_size(ingest) == 0 do
      attributes
    else
      Map.put(attributes, "serviceradar.ingest", ingest)
    end
  end

  defp attach_ingest_metadata(attributes, _metadata, _subject), do: attributes || %{}

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_text_columns(row) when is_map(row) do
    row
    |> maybe_stringify_text(:trace_id)
    |> maybe_stringify_text(:span_id)
    |> maybe_stringify_text(:severity_text)
    |> maybe_stringify_text(:body)
    |> maybe_stringify_text(:event_name)
    |> maybe_stringify_text(:source)
    |> maybe_stringify_text(:service_name)
    |> maybe_stringify_text(:service_version)
    |> maybe_stringify_text(:service_instance)
    |> maybe_stringify_text(:scope_name)
    |> maybe_stringify_text(:scope_version)
    |> maybe_encode_text(:attributes)
    |> maybe_encode_text(:resource_attributes)
    |> maybe_encode_text(:scope_attributes)
  end

  defp maybe_encode_text(row, key) do
    case Map.get(row, key) do
      value when is_map(value) or is_list(value) ->
        Map.put(row, key, FieldParser.encode_json(value))

      _ ->
        row
    end
  end

  defp maybe_stringify_text(row, key) do
    case Map.get(row, key) do
      nil -> row
      value when is_binary(value) -> row
      value -> Map.put(row, key, to_string(value))
    end
  end

  defp emit_drop(reason, subject) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :trivy, :dropped],
      %{count: 1},
      %{reason: reason, subject: subject || "trivy.report.unknown"}
    )

    Logger.debug("Dropped Trivy message", reason: inspect(reason), subject: subject)
  end
end
