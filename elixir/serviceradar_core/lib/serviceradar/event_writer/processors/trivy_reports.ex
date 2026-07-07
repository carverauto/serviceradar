defmodule ServiceRadar.EventWriter.Processors.TrivyReports do
  @moduledoc """
  Processor for Trivy Operator report envelopes published by `trivy-sidecar`.

  Dual-path behavior:
  - Persist all Trivy payloads into `logs` as raw observability records.
  - Auto-promote higher-priority findings into `ocsf_events`.
  - Auto-create alerts for critical promoted events.

  ## Routine "scan completed" status events are suppressed by default

  Every processed report used to also emit a `"Trivy scan completed: ..."` OCSF
  `scan_activity` event (Informational severity, always `Success`) into
  `ocsf_events`. Because trivy-operator produces a report for *every* workload and
  re-scans them all on any change (e.g. after a roll), these routine status
  heartbeats flooded the observability stream — during the v1.4.6 roll they were
  ~88% of all `ocsf_events` (801 in 3 minutes) — while carrying no actionable
  signal.

  To keep the observability stream signal-rich, the per-report scan-completed
  `scan_activity` event is **not** written to `ocsf_events` by default. The real
  signal is unaffected:

  - Actionable findings (new/changed vulnerabilities, exposed secrets, failed
    config-audits) at high severity or above are still promoted into `ocsf_events`
    as `finding` events (see `promote_to_event?/1`).
  - The full report and every individual finding are still persisted to
    `trivy_reports` / `trivy_findings`, and the raw payload to `logs`, regardless
    of this flag.

  Operators who want the scan-completed heartbeat back in the OCSF event stream
  can re-enable it via application env:

      config :serviceradar_core, :trivy_scan_activity_events, true

  The flag defaults to `false`.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  import Bitwise

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Observability.LogPubSub
  alias ServiceRadar.Observability.StatefulAlertEngine

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

  @severity_level_map %{
    "critical" => :critical,
    "high" => :high,
    "medium" => :medium,
    "low" => :low,
    "none" => :informational,
    "info" => :informational,
    "informational" => :informational
  }

  @impl true
  def table_name, do: "logs"

  @doc false
  @spec promote_to_event?(non_neg_integer()) :: boolean()
  def promote_to_event?(severity_id), do: severity_id >= OCSF.severity_high()

  @doc false
  @spec promote_to_alert?(non_neg_integer()) :: boolean()
  def promote_to_alert?(severity_id), do: severity_id >= OCSF.severity_critical()

  @doc false
  # Whether routine Trivy "scan completed" (OCSF `scan_activity`) status events
  # should be mirrored into `ocsf_events`. Off by default: trivy-operator emits a
  # report for EVERY workload on every re-scan, so these Informational,
  # always-`Success` heartbeats flood `ocsf_events` while carrying no actionable
  # signal. The real signal (promoted `finding` events plus the persisted
  # `trivy_reports` / `trivy_findings` rows) is unaffected by this flag. See the
  # moduledoc for the `:trivy_scan_activity_events` override. Exposed (not `defp`)
  # so tests can assert the gate directly.
  @spec emit_scan_activity_events?() :: boolean()
  def emit_scan_activity_events? do
    Application.get_env(:serviceradar_core, :trivy_scan_activity_events, false) == true
  end

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

      finding_rows = Enum.flat_map(entries, & &1.finding_rows)

      finding_count = upsert_finding_rows(finding_rows)

      scan_activity_rows =
        if emit_scan_activity_events?() do
          Enum.map(entries, & &1.scan_activity_row)
        else
          []
        end

      promoted_rows =
        scan_activity_rows ++
          (entries
           |> Enum.filter(fn entry -> promote_to_event?(entry.severity_id) end)
           |> Enum.map(& &1.event_row))

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

  @doc false
  def parse_event_rows(%{data: _data, metadata: _metadata} = message) do
    case parse_entry(message) do
      %{event_row: event_row, scan_activity_row: scan_activity_row} ->
        [scan_activity_row, event_row]

      _ ->
        []
    end
  end

  def parse_event_rows(_), do: []

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

    scan_activity_row =
      build_scan_activity_row(%{
        event_uuid: event_uuid,
        log_uuid: log_uuid,
        payload: payload,
        subject: subject,
        raw_data: raw_data,
        event_time: event_time,
        message: message,
        context: context,
        severity: severity
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
        log_uuid: log_uuid,
        payload: payload,
        event_time: event_time,
        context: context
      })

    {:ok,
     %{
       log_row: log_row,
       report_row: report_row,
       finding_rows: finding_rows,
       scan_activity_row: scan_activity_row,
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
      attach_ingest_metadata(
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
        },
        metadata,
        subject
      )

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
    agent_id = trivy_agent_id(context)
    device_uid = trivy_device_uid(payload, context)

    metadata =
      payload
      |> build_event_metadata(subject, context)
      |> Map.put("finding_info", build_finding_info(payload, context, event_uuid, message))
      |> Map.put("security_signal", %{
        "source" => "trivy",
        "finding_uid" => finding_uid(payload, event_uuid)
      })
      |> Map.put("service_radar", %{
        "source_log_id" => log_uuid,
        "promotion" => "trivy_priority_auto",
        "source_type" => "trivy",
        "finding_uid" => finding_uid(payload, event_uuid),
        "agent_id" => agent_id,
        "device_uid" => device_uid,
        "device_hostname" => context["node_name"],
        "device_ip" => context["host_ip"],
        "pod_name" => context["pod_name"],
        "pod_uid" => context["pod_uid"],
        "pod_ip" => context["pod_ip"],
        "namespace" => context["pod_namespace"] || context["resource_namespace"],
        "resource_kind" => context["resource_kind"],
        "resource_name" => context["resource_name"]
      })

    src_endpoint =
      if is_binary(context["pod_ip"]) and context["pod_ip"] != "" do
        OCSF.build_endpoint(ip: context["pod_ip"], name: context["pod_name"])
      else
        %{}
      end

    class_uid = trivy_finding_class_uid(payload, context)

    %{
      id: Ecto.UUID.dump!(event_uuid),
      time: event_time,
      class_uid: class_uid,
      category_uid: OCSF.category_findings(),
      type_uid: OCSF.type_uid(class_uid, OCSF.activity_finding_create()),
      activity_id: OCSF.activity_finding_create(),
      activity_name: OCSF.finding_activity_name(OCSF.activity_finding_create()),
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
      device: build_device(payload, context, device_uid),
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

  defp build_scan_activity_row(%{
         event_uuid: event_uuid,
         log_uuid: log_uuid,
         payload: payload,
         subject: subject,
         raw_data: raw_data,
         event_time: event_time,
         message: message,
         context: context,
         severity: severity
       }) do
    scan_uuid = deterministic_uuid("#{event_uuid}:trivy:scan_activity")
    agent_id = trivy_agent_id(context)
    device_uid = trivy_device_uid(payload, context)

    metadata =
      payload
      |> build_event_metadata(subject, context)
      |> Map.put("service_radar", %{
        "source_log_id" => log_uuid,
        "promotion" => "trivy_scan_activity",
        "source_type" => "trivy",
        "agent_id" => agent_id,
        "device_uid" => device_uid,
        "device_hostname" => context["node_name"],
        "device_ip" => context["host_ip"],
        "pod_name" => context["pod_name"],
        "pod_uid" => context["pod_uid"],
        "pod_ip" => context["pod_ip"],
        "namespace" => context["pod_namespace"] || context["resource_namespace"],
        "resource_kind" => context["resource_kind"],
        "resource_name" => context["resource_name"],
        "scan_id" => normalize_string(payload["event_id"]),
        "ocsf_class" => "scan_activity"
      })

    activity_id = OCSF.activity_scan_completed()
    class_uid = OCSF.class_scan_activity()

    %{
      id: Ecto.UUID.dump!(scan_uuid),
      time: event_time,
      class_uid: class_uid,
      category_uid: OCSF.category_application_activity(),
      type_uid: OCSF.type_uid(class_uid, activity_id),
      activity_id: activity_id,
      activity_name: OCSF.scan_activity_name(activity_id),
      severity_id: OCSF.severity_informational(),
      severity: OCSF.severity_name(OCSF.severity_informational()),
      message: "Trivy scan completed: #{message}",
      status_id: OCSF.status_success(),
      status: OCSF.status_name(OCSF.status_success()),
      status_code: "trivy_report_processed",
      status_detail: nil,
      metadata: metadata,
      observables: build_observables(payload, context),
      trace_id: nil,
      span_id: nil,
      actor: build_actor(payload),
      device: build_device(payload, context, device_uid),
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: subject,
      log_provider: "trivy",
      log_level: "INFO",
      log_version: "1.0",
      unmapped:
        payload
        |> Map.take(["event_id", "report_kind", "cluster_id", "namespace", "name", "uid"])
        |> Map.put("findings_count", severity.findings_count),
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
      payload["summary"]
      |> normalize_map()
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
         log_uuid: log_uuid,
         payload: payload,
         event_time: event_time,
         context: context
       }) do
    report_payload = normalize_map(get_in(payload, ["report", "report"]))
    artifact = normalize_map(report_payload["artifact"])
    event_uuid_bin = Ecto.UUID.dump!(event_uuid)
    log_uuid_bin = Ecto.UUID.dump!(log_uuid)
    report_kind = normalize_string(payload["report_kind"]) || "TrivyReport"
    target = report_target(report_payload, context)
    now = DateTime.utc_now()

    common =
      %{
        event_uuid: event_uuid_bin,
        log_uuid: log_uuid_bin,
        observed_at: event_time,
        report_kind: report_kind,
        cluster_id: normalize_string(payload["cluster_id"]),
        namespace: normalize_string(payload["namespace"]),
        agent_id: trivy_agent_id(context),
        device_uid: trivy_device_uid(payload, context),
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
        image_repository: normalize_string(artifact["repository"]),
        image_tag: normalize_string(artifact["tag"]),
        image_digest: normalize_string(artifact["digest"]),
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
        |> Map.put(:package_purl, package_purl(vulnerability))
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
        |> Map.put(:package_purl, nil)
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
        |> Map.put(:package_purl, nil)
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

    insert_all_count("logs", rows_for_insert,
      on_conflict: :nothing,
      returning: false
    )
  end

  defp insert_all_count(_table, [], _opts), do: 0

  defp insert_all_count(table, rows, opts) do
    {count, _} = BulkInsert.insert_all(table, rows, opts)

    count
  end

  defp insert_all_returning(_table, [], _opts), do: {0, []}

  defp insert_all_returning(table, rows, opts) do
    BulkInsert.insert_all(table, rows, opts)
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

    insert_all_count("trivy_reports", rows,
      on_conflict: {:replace, updatable_columns},
      conflict_target: [:event_uuid],
      returning: false
    )
  end

  defp upsert_finding_rows([]), do: 0

  defp upsert_finding_rows(rows) do
    rows = dedupe_rows_by_conflict_key(rows, &Map.get(&1, :fingerprint))

    updatable_columns = [
      :event_uuid,
      :log_uuid,
      :observed_at,
      :report_kind,
      :cluster_id,
      :namespace,
      :agent_id,
      :device_uid,
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
      :image_repository,
      :image_tag,
      :image_digest,
      :finding_type,
      :finding_id,
      :target,
      :title,
      :severity_text,
      :severity_id,
      :status,
      :package_name,
      :package_purl,
      :installed_version,
      :fixed_version,
      :description,
      :references,
      :raw_finding,
      :updated_at
    ]

    insert_all_count("trivy_findings", rows,
      on_conflict: {:replace, updatable_columns},
      conflict_target: [:fingerprint],
      returning: false
    )
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
    rows = dedupe_rows_by_conflict_key(rows, &Map.get(&1, :id))

    {:ok, result} =
      ServiceRadar.Repo.transaction(
        fn ->
          lock_trivy_event_rows()
          delete_existing_trivy_event_rows(rows)

          {count, inserted} =
            insert_all_returning("ocsf_events", rows,
              on_conflict: :nothing,
              conflict_target: [:time, :id],
              returning: [:time, :id]
            )

          inserted_keys =
            MapSet.new(Enum.map(inserted, fn row -> ocsf_event_conflict_key(row) end))

          inserted_rows =
            rows
            |> Enum.filter(&MapSet.member?(inserted_keys, ocsf_event_conflict_key(&1)))
            |> dedupe_rows_by_conflict_key(&Map.get(&1, :id))

          {count, inserted_rows}
        end,
        timeout: :infinity
      )

    result
  end

  defp lock_trivy_event_rows do
    ServiceRadar.Repo.query!(
      "SELECT pg_advisory_xact_lock($1::bigint)",
      [7_284_636_437_057_309_481]
    )
  end

  defp ocsf_event_conflict_key(row) when is_map(row) do
    {Map.get(row, :time), Map.get(row, :id)}
  end

  defp delete_existing_trivy_event_rows(rows) when is_list(rows) do
    ids =
      rows
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.map(&uuid_param/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(Enum.chunk_every(ids, 500), fn chunk ->
      ServiceRadar.Repo.query!(
        """
        DELETE FROM platform.ocsf_events
        WHERE id = ANY($1::uuid[])
          AND COALESCE(
            metadata->'service_radar'->>'source_type',
            metadata->'serviceradar'->>'source_type',
            log_provider
          ) = 'trivy'
        """,
        [chunk]
      )
    end)
  end

  defp uuid_param(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end

  defp uuid_param(_value), do: nil

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
      payload["summary"]
      |> normalize_map()
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
    severity_id
    |> OCSF.severity_name()
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
      "version" => "1.9.0-dev",
      "product" => %{
        "name" => "Trivy",
        "vendor_name" => "Aqua Security"
      },
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

  defp build_finding_info(payload, context, event_uuid, message) do
    uid = finding_uid(payload, event_uuid)

    %{
      "uid" => uid,
      "group_uid" => uid,
      "title" => message,
      "source" => "trivy",
      "dimensions" =>
        %{}
        |> maybe_put("report_kind", normalize_string(payload["report_kind"]))
        |> maybe_put("cluster_id", normalize_string(payload["cluster_id"]))
        |> maybe_put("namespace", context["resource_namespace"])
        |> maybe_put("resource_kind", context["resource_kind"])
        |> maybe_put("resource_name", context["resource_name"])
        |> maybe_put("pod_name", context["pod_name"])
        |> maybe_put("pod_uid", context["pod_uid"])
        |> maybe_put("node_name", context["node_name"])
    }
  end

  defp finding_uid(payload, event_uuid) do
    normalize_string(payload["event_id"]) ||
      normalize_string(payload["uid"]) ||
      event_uuid
  end

  defp trivy_finding_class_uid(payload, context) do
    kind =
      payload
      |> Map.get("report_kind")
      |> normalize_string()
      |> case do
        nil -> ""
        value -> String.downcase(value)
      end

    resource_kind =
      context
      |> Map.get("resource_kind")
      |> normalize_string()
      |> case do
        nil -> ""
        value -> String.downcase(value)
      end

    cond do
      String.contains?(kind, "config") or String.contains?(kind, "rbac") ->
        OCSF.class_compliance_finding()

      String.contains?(kind, "infra") or String.contains?(kind, "exposed") or
          String.contains?(resource_kind, "exposed") ->
        OCSF.class_application_security_posture_finding()

      true ->
        OCSF.class_vulnerability_finding()
    end
  end

  defp build_observables(payload, context) do
    artifact = normalize_map(get_in(payload, ["report", "report", "artifact"]))

    Enum.reject(
      [
        maybe_observable(context["pod_ip"], "IP Address", 2),
        maybe_observable(context["pod_name"], "Kubernetes Pod", 99),
        maybe_observable(resource_label(context), "Resource", 99),
        maybe_observable(normalize_string(artifact["repository"]), "Image Repository", 99),
        maybe_observable(normalize_string(payload["uid"]), "Kubernetes UID", 99)
      ],
      &is_nil/1
    )
  end

  defp build_actor(payload) do
    scanner = normalize_map(get_in(payload, ["report", "report", "scanner"]))

    OCSF.build_actor(
      app_name: normalize_string(scanner["name"]) || "trivy",
      app_ver: normalize_string(scanner["version"])
    )
  end

  defp build_device(_payload, context, device_uid) do
    hostname = context["node_name"]

    uid =
      device_uid ||
        hostname ||
        context["host_ip"] ||
        context["resource_name"]

    OCSF.build_device(
      uid: uid,
      name: hostname || context["resource_name"] || context["pod_name"],
      hostname: hostname,
      ip: context["host_ip"] || context["pod_ip"]
    )
  end

  defp trivy_device_uid(payload, context) do
    correlation = normalize_map(payload["correlation"])

    explicit =
      normalize_string(context["device_uid"]) ||
        normalize_string(correlation["device_uid"]) ||
        normalize_string(correlation["device_id"]) ||
        normalize_string(payload["device_uid"]) ||
        normalize_string(payload["device_id"])

    DeviceCorrelation.resolve(%{
      device_uid: explicit,
      agent_id: trivy_agent_id(context),
      pod_uid: context["pod_uid"],
      pod_namespace: context["pod_namespace"],
      pod_name: context["pod_name"],
      container_id: context["container_id"],
      hostname: context["node_name"],
      name: context["resource_name"] || context["pod_name"],
      ip: context["host_ip"] || context["pod_ip"],
      partition: context["partition"]
    })
  end

  defp trivy_agent_id(context) do
    normalize_string(context["agent_id"]) || inferred_agent_id(context["node_name"])
  end

  defp inferred_agent_id(nil), do: nil
  defp inferred_agent_id("agent-" <> _ = agent_id), do: agent_id
  defp inferred_agent_id(hostname), do: "agent-#{hostname}"

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

  defp package_purl(vulnerability) when is_map(vulnerability) do
    pick_string(vulnerability, [
      "purl",
      "PURL",
      "pkgPURL",
      "PkgPURL",
      "packagePurl",
      "packagePURL"
    ]) ||
      vulnerability
      |> Map.get("pkgIdentifier")
      |> normalize_map()
      |> pick_string(["purl", "PURL"])
  end

  defp package_purl(_vulnerability), do: nil

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
    |> String.downcase()
    |> then(&Map.get(@finding_severity_map, &1, OCSF.severity_unknown()))
  end

  defp finding_fingerprint(row) do
    fingerprint_source =
      Enum.map_join(
        [
          row.event_uuid,
          row.finding_type,
          row.finding_id,
          row.title,
          row.package_name,
          row.target,
          row.pod_ip
        ],
        "|",
        &to_string_safe/1
      )

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
      first_present([
        correlation["resource_kind"],
        labels["trivy-operator.resource.kind"]
      ])

    resource_name =
      first_present([
        correlation["resource_name"],
        labels["trivy-operator.resource.name"],
        payload["name"]
      ])

    resource_namespace =
      first_present([
        correlation["resource_namespace"],
        labels["trivy-operator.resource.namespace"],
        payload["namespace"]
      ])

    owner_kind = first_present([correlation["owner_kind"], owner["kind"]])
    owner_name = first_present([correlation["owner_name"], owner["name"]])
    owner_uid = first_present([correlation["owner_uid"], owner["uid"]])

    pod_name =
      first_present([
        correlation["pod_name"],
        infer_pod_name(resource_kind, resource_name, owner_kind, owner_name)
      ])

    pod_namespace =
      first_present([
        correlation["pod_namespace"],
        pod_namespace_for(pod_name, resource_namespace)
      ])

    pod_uid =
      first_present([
        correlation["pod_uid"],
        pod_uid_for(owner_kind, owner_uid)
      ])

    %{
      "agent_id" => first_present([correlation["agent_id"], payload["agent_id"]]),
      "device_uid" => first_present([correlation["device_uid"], payload["device_uid"]]),
      "partition" => first_present([correlation["partition"], payload["partition"]]),
      "resource_kind" => resource_kind,
      "resource_name" => resource_name,
      "resource_namespace" => resource_namespace,
      "container_name" => first_present([correlation["container_name"]]),
      "owner_kind" => owner_kind,
      "owner_name" => owner_name,
      "owner_uid" => owner_uid,
      "pod_name" => pod_name,
      "pod_namespace" => pod_namespace,
      "pod_uid" => pod_uid,
      "pod_ip" => first_present([correlation["pod_ip"]]),
      "host_ip" => first_present([correlation["host_ip"]]),
      "node_name" => first_present([correlation["node_name"]])
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

    if is_binary(event_id) do
      case Ecto.UUID.cast(event_id) do
        {:ok, cast_uuid} -> cast_uuid
        :error -> deterministic_uuid("#{subject}:event_id:#{String.downcase(event_id)}")
      end
    else
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

  defp pod?(value) when is_binary(value), do: String.downcase(value) == "pod"
  defp pod?(_), do: false

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
    value
    |> normalize_string()
    |> normalize_severity_key()
    |> then(&Map.get(@severity_level_map, &1, :unknown))
  end

  defp normalize_severity_key(nil), do: "unknown"
  defp normalize_severity_key(value), do: String.downcase(value)

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, &normalize_string/1)
  end

  defp infer_pod_name(resource_kind, resource_name, owner_kind, owner_name) do
    cond do
      pod?(resource_kind) -> resource_name
      pod?(owner_kind) -> owner_name
      true -> nil
    end
  end

  defp pod_namespace_for(pod_name, resource_namespace) when is_binary(pod_name),
    do: resource_namespace

  defp pod_namespace_for(_pod_name, _resource_namespace), do: nil

  defp pod_uid_for(owner_kind, owner_uid) do
    if pod?(owner_kind), do: owner_uid
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
    versioned_a3 = a3 |> band(0x0FFF) |> bor(0x4000)
    versioned_a4 = a4 |> band(0x3FFF) |> bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
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
