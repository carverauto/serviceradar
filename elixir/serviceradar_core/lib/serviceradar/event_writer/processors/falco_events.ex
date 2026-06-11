defmodule ServiceRadar.EventWriter.Processors.FalcoEvents do
  @moduledoc """
  Processor for Falco runtime security events published via NATS JetStream.

  Dual-path behavior:
  - Persist all Falco payloads into `logs` as raw observability records.
  - Auto-promote higher-priority Falco payloads into `ocsf_events`.
  - Evaluate promoted events against stateful alert rules for incident handling.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  import Bitwise

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.LogPubSub
  alias ServiceRadar.Observability.StatefulAlertEngine

  require Logger

  @fallback_time DateTime.from_unix!(0)

  @priority_map %{
    "emergency" => {OCSF.severity_fatal(), OCSF.status_failure()},
    "alert" => {OCSF.severity_fatal(), OCSF.status_failure()},
    "critical" => {OCSF.severity_critical(), OCSF.status_failure()},
    "error" => {OCSF.severity_high(), OCSF.status_failure()},
    "err" => {OCSF.severity_high(), OCSF.status_failure()},
    "warning" => {OCSF.severity_medium(), OCSF.status_failure()},
    "warn" => {OCSF.severity_medium(), OCSF.status_failure()},
    "notice" => {OCSF.severity_low(), OCSF.status_success()},
    "informational" => {OCSF.severity_informational(), OCSF.status_success()},
    "info" => {OCSF.severity_informational(), OCSF.status_success()},
    "debug" => {OCSF.severity_informational(), OCSF.status_success()}
  }

  @severity_to_otel %{
    6 => 24,
    5 => 20,
    4 => 17,
    3 => 13,
    2 => 9,
    1 => 5,
    0 => 1
  }

  @impl true
  def table_name, do: "logs"

  @doc false
  @spec promote_to_event?(non_neg_integer()) :: boolean()
  def promote_to_event?(severity_id), do: severity_id >= OCSF.severity_medium()

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

      promoted_rows =
        entries
        |> Enum.filter(fn entry -> promote_to_event?(entry.severity_id) end)
        |> Enum.map(& &1.event_row)
        |> dedupe_rows_by_conflict_key(&Map.get(&1, :id))

      {event_count, inserted_events} = insert_event_rows(promoted_rows)
      maybe_broadcast_logs(log_count)
      maybe_broadcast_events(event_count)
      maybe_evaluate_stateful_rules(inserted_events)

      :telemetry.execute(
        [:serviceradar, :event_writer, :falco, :processed],
        %{logs_count: log_count, events_count: event_count, alerts_count: 0},
        %{}
      )

      {:ok, log_count}
    end
  rescue
    e ->
      Logger.error("Falco events batch processing failed: #{inspect(e)}")
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
      Logger.warning("Failed to parse Falco event",
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
    output_fields = falco_output_fields(payload)

    event_time = parse_event_time(payload["time"], output_fields)
    event_uuid = resolve_event_id(payload, subject, raw_data)
    log_uuid = deterministic_uuid("#{event_uuid}:log")

    priority = payload["priority"]
    {severity_id, status_id} = severity_status_for_priority(priority)

    message = event_message(payload, subject)

    log_row =
      build_log_row(
        log_uuid,
        payload,
        subject,
        output_fields,
        metadata,
        event_time,
        severity_id,
        message
      )

    event_row =
      build_event_row(%{
        event_uuid: event_uuid,
        log_uuid: log_uuid,
        payload: payload,
        subject: subject,
        output_fields: output_fields,
        raw_data: raw_data,
        event_time: event_time,
        severity_id: severity_id,
        status_id: status_id,
        message: message
      })

    {:ok,
     %{
       log_row: log_row,
       event_row: event_row,
       severity_id: severity_id
     }}
  end

  defp build_log_row(
         log_uuid,
         payload,
         subject,
         output_fields,
         metadata,
         event_time,
         severity_id,
         message
       ) do
    priority = normalize_string(payload["priority"])

    attributes =
      attach_ingest_metadata(
        %{
          "falco" => %{
            "uuid" => normalize_string(payload["uuid"]),
            "rule" => normalize_string(payload["rule"]),
            "priority" => priority,
            "output" => normalize_string(payload["output"]),
            "source" => normalize_string(payload["source"]),
            "tags" => normalize_tags(payload["tags"]),
            "output_fields" => output_fields
          }
        },
        metadata,
        subject
      )

    resource_attributes =
      %{}
      |> maybe_put("host.name", normalize_string(payload["hostname"]))
      |> maybe_put("k8s.namespace.name", normalize_string(output_fields["k8s.ns.name"]))
      |> maybe_put("k8s.pod.name", normalize_string(output_fields["k8s.pod.name"]))
      |> maybe_put("container.id", normalize_string(output_fields["container.id"]))
      |> maybe_put("container.name", normalize_string(output_fields["container.name"]))

    %{
      id: Ecto.UUID.dump!(log_uuid),
      timestamp: event_time,
      observed_timestamp: observed_timestamp(metadata[:received_at], event_time),
      trace_id: nil,
      span_id: nil,
      trace_flags: nil,
      severity_text: priority,
      severity_number: Map.get(@severity_to_otel, severity_id, 1),
      body: message,
      event_name: normalize_string(payload["rule"]),
      source: "falco",
      service_name: "falco",
      service_version: nil,
      service_instance: normalize_string(payload["hostname"]),
      scope_name: "falcosidekick",
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
         output_fields: output_fields,
         raw_data: raw_data,
         event_time: event_time,
         severity_id: severity_id,
         status_id: status_id,
         message: message
       }) do
    device_hostname = falco_device_hostname(payload, output_fields)
    agent_id = falco_agent_id(payload, output_fields, device_hostname)
    device_uid = falco_device_uid(payload, output_fields, device_hostname)

    metadata =
      payload
      |> build_event_metadata(subject, output_fields)
      |> Map.put("service_radar", %{
        "source_log_id" => log_uuid,
        "promotion" => "falco_priority_auto",
        "source_type" => "falco",
        "agent_id" => agent_id,
        "device_uid" => device_uid,
        "device_hostname" => device_hostname,
        "node_name" => normalize_string(output_fields["k8s.node.name"]),
        "container_id" => normalize_string(output_fields["container.id"]),
        "container_name" => normalize_string(output_fields["container.name"]),
        "pod_name" => normalize_string(output_fields["k8s.pod.name"]),
        "namespace" => normalize_string(output_fields["k8s.ns.name"])
      })

    %{
      id: Ecto.UUID.dump!(event_uuid),
      time: event_time,
      class_uid: OCSF.class_detection_finding(),
      category_uid: OCSF.category_findings(),
      type_uid: OCSF.type_uid(OCSF.class_detection_finding(), OCSF.activity_finding_create()),
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
      observables: build_observables(payload, output_fields),
      trace_id: nil,
      span_id: nil,
      actor: build_actor(output_fields),
      device: build_device(payload, output_fields, device_uid),
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: subject,
      log_provider: "falco",
      log_level: normalize_string(payload["priority"]),
      log_version: "1.0",
      unmapped: payload,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp insert_log_rows([]), do: 0

  defp insert_log_rows(rows) do
    rows_for_insert = Enum.map(rows, &encode_text_columns/1)

    {count, _} =
      ServiceRadar.Repo.insert_all("logs", rows_for_insert,
        on_conflict: :nothing,
        returning: false
      )

    count
  end

  defp insert_event_rows([]), do: {0, []}

  defp insert_event_rows(rows) do
    {count, inserted} =
      ServiceRadar.Repo.insert_all("ocsf_events", rows,
        on_conflict: :nothing,
        returning: [:id]
      )

    inserted_ids = MapSet.new(Enum.map(inserted, & &1.id))

    inserted_rows =
      rows
      |> Enum.filter(&MapSet.member?(inserted_ids, &1.id))
      |> dedupe_rows_by_conflict_key(&Map.get(&1, :id))
      |> Enum.map(&decode_inserted_event_row/1)

    {count, inserted_rows}
  end

  defp decode_inserted_event_row(row) when is_map(row) do
    Map.update(row, :id, nil, &load_uuid/1)
  end

  defp load_uuid(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp load_uuid(value), do: value

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
        Logger.warning("Stateful alert evaluation failed for Falco events: #{inspect(reason)}")
        :ok
    end
  end

  defp severity_status_for_priority(priority) do
    normalized =
      priority
      |> normalize_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    Map.get(@priority_map, normalized, {OCSF.severity_unknown(), OCSF.status_other()})
  end

  defp event_message(payload, subject) do
    normalize_string(payload["output"]) ||
      normalize_string(payload["body"]) ||
      normalize_string(payload["message"]) ||
      normalize_string(payload["rule"]) ||
      subject || "falco event"
  end

  defp falco_output_fields(payload) do
    payload["output_fields"]
    |> normalize_map()
    |> Map.merge(normalize_map(payload["custom_fields"]))
    |> Map.merge(normalize_map(payload["templated_fields"]))
  end

  defp build_event_metadata(payload, subject, output_fields) do
    context = falco_context(payload, output_fields)
    diagnostics = falco_diagnostics(payload, output_fields, context)

    %{
      "version" => "1.9.0-dev",
      "product" => %{
        "name" => "Falco",
        "vendor_name" => "The Falco Authors"
      },
      "source" => "falco",
      "subject" => subject,
      "uuid" => normalize_string(payload["uuid"]),
      "rule" => normalize_string(payload["rule"]),
      "priority" => normalize_string(payload["priority"]),
      "hostname" => normalize_string(payload["hostname"]),
      "source_type" => normalize_string(payload["source"]),
      "tags" => normalize_tags(payload["tags"]),
      "output_fields" => output_fields,
      "security_signal" =>
        compact_map(%{
          "kind" => "runtime",
          "source" => "falco",
          "rule" => context["rule"],
          "priority" => context["priority"],
          "uuid" => normalize_string(payload["uuid"]),
          "diagnostics" => diagnostics
        })
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp falco_context(payload, output_fields) do
    hostname = falco_device_hostname(payload, output_fields)

    %{
      "rule" => normalize_string(payload["rule"]),
      "priority" => normalize_string(payload["priority"]),
      "hostname" => hostname,
      "namespace" => normalize_string(output_fields["k8s.ns.name"]),
      "pod" => normalize_string(output_fields["k8s.pod.name"]),
      "container" => normalize_string(output_fields["container.name"]),
      "container_id" => normalize_string(output_fields["container.id"])
    }
  end

  defp falco_diagnostics(payload, output_fields, context) do
    compact_map(%{
      "rule" => %{
        "name" => context["rule"],
        "priority" => context["priority"],
        "uuid" => normalize_string(payload["uuid"]),
        "source" => normalize_string(payload["source"]),
        "tags" => normalize_tags(payload["tags"]),
        "references" => falco_references(payload, output_fields)
      },
      "host" => %{"name" => context["hostname"]},
      "process" => falco_process_diagnostics(output_fields),
      "parent_process" => falco_parent_process_diagnostics(output_fields),
      "user" => falco_user_diagnostics(output_fields),
      "file" => falco_file_diagnostics(output_fields),
      "network" => falco_network_diagnostics(output_fields),
      "container" =>
        falco_container_diagnostics(output_fields, %{
          "name" => context["container"],
          "id" => context["container_id"]
        }),
      "kubernetes" => %{
        "namespace" => context["namespace"],
        "pod" => context["pod"],
        "node" => normalize_string(output_fields["k8s.node.name"])
      },
      "event" => falco_event_diagnostics(output_fields, payload),
      "attribution" =>
        falco_attribution(
          context["namespace"],
          context["pod"],
          context["container"],
          context["container_id"]
        )
    })
  end

  defp falco_process_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["proc.name"]),
      "short_name" => falco_field(output_fields, ["proc.sname"]),
      "executable" => falco_field(output_fields, ["proc.exe", "proc.exepath"]),
      "executable_path" => falco_field(output_fields, ["proc.exepath"]),
      "command" => falco_field(output_fields, ["proc.cmdline", "proc.args"]),
      "cwd" => falco_field(output_fields, ["proc.cwd"]),
      "tty" => falco_field(output_fields, ["proc.tty"]),
      "pid" => falco_field(output_fields, ["proc.pid"]),
      "executable_flags" =>
        compact_map(%{
          "upper_layer" => falco_field(output_fields, ["proc.is_exe_upper_layer"]),
          "from_memfd" => falco_field(output_fields, ["proc.is_exe_from_memfd"]),
          "from_disk" => falco_field(output_fields, ["proc.is_exe_from_disk"]),
          "lower_layer" => falco_field(output_fields, ["proc.is_exe_lower_layer"]),
          "evt_flags" => falco_field(output_fields, ["evt.arg.flags"])
        })
    })
  end

  defp falco_parent_process_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["proc.pname"]),
      "ancestor" => falco_field(output_fields, ["proc.aname[2]", "proc.aname[3]"])
    })
  end

  defp falco_user_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["user.name"]),
      "uid" => falco_field(output_fields, ["user.uid"]),
      "login_uid" => falco_field(output_fields, ["user.loginuid"])
    })
  end

  defp falco_file_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["fd.name", "evt.arg.path", "evt.arg.name"]),
      "directory" => falco_field(output_fields, ["fd.directory"]),
      "type" => falco_field(output_fields, ["fd.type"]),
      "num" => falco_field(output_fields, ["fd.num"]),
      "flags" => falco_field(output_fields, ["evt.arg.flags", "fd.flags"])
    })
  end

  defp falco_network_diagnostics(output_fields) do
    compact_map(%{
      "source_ip" => falco_field(output_fields, ["fd.sip", "evt.arg.sip"]),
      "source_port" => falco_field(output_fields, ["fd.sport", "evt.arg.sport"]),
      "destination_ip" => falco_field(output_fields, ["fd.dip", "evt.arg.dip"]),
      "destination_port" => falco_field(output_fields, ["fd.dport", "evt.arg.dport"]),
      "l4_protocol" => falco_field(output_fields, ["fd.l4proto"]),
      "remote_ip" => falco_field(output_fields, ["fd.rip"]),
      "remote_port" => falco_field(output_fields, ["fd.rport"])
    })
  end

  defp falco_container_diagnostics(output_fields, context) do
    compact_map(%{
      "id" => context["id"],
      "name" => context["name"],
      "image" => falco_field(output_fields, ["container.image"]),
      "image_repository" => falco_field(output_fields, ["container.image.repository"]),
      "image_tag" => falco_field(output_fields, ["container.image.tag"]),
      "image_digest" => falco_field(output_fields, ["container.image.digest"])
    })
  end

  defp falco_event_diagnostics(output_fields, payload) do
    compact_map(%{
      "type" => falco_field(output_fields, ["evt.type"]),
      "time" => falco_field(output_fields, ["evt.time"]) || normalize_string(payload["time"]),
      "flags" => falco_field(output_fields, ["evt.arg.flags"])
    })
  end

  defp falco_attribution(namespace, pod, container, container_id) do
    status =
      cond do
        present?(namespace) and present?(pod) ->
          "resolved"

        present?(namespace) or present?(pod) or present?(container) or present?(container_id) ->
          "partial"

        true ->
          "missing"
      end

    missing =
      Enum.reject(
        [
          if(present?(namespace), do: nil, else: "kubernetes.namespace"),
          if(present?(pod), do: nil, else: "kubernetes.pod")
        ],
        &is_nil/1
      )

    compact_map(%{
      "status" => status,
      "missing" => missing
    })
  end

  defp falco_references(payload, output_fields) do
    [
      payload["rule_url"],
      payload["rule_uri"],
      payload["url"],
      output_fields["falco.rule.url"],
      output_fields["falco.rule_uri"]
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp falco_field(output_fields, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case falco_value(output_fields[key]) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  defp falco_value(value) when is_binary(value) do
    normalize_string(value)
  end

  defp falco_value(value) when value in [nil, "", []], do: nil
  defp falco_value(value), do: value

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = compact_value(value)

      if empty_value?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact_value(value) when is_map(value), do: compact_map(value)

  defp compact_value(value) when is_list(value) do
    value
    |> Enum.map(&compact_value/1)
    |> Enum.reject(&empty_value?/1)
  end

  defp compact_value(value), do: value

  defp empty_value?(nil), do: true
  defp empty_value?(""), do: true
  defp empty_value?([]), do: true
  defp empty_value?(value) when is_map(value), do: map_size(value) == 0
  defp empty_value?(_value), do: false

  defp present?(value), do: not empty_value?(value)

  defp build_observables(payload, output_fields) do
    Enum.reject(
      [
        maybe_observable(normalize_string(payload["hostname"]), "Hostname", 1),
        maybe_observable(normalize_string(payload["rule"]), "Rule Name", 99),
        maybe_observable(normalize_string(output_fields["container.id"]), "Container ID", 99),
        maybe_observable(normalize_string(output_fields["k8s.pod.name"]), "Kubernetes Pod", 99)
      ],
      &is_nil/1
    )
  end

  defp build_actor(output_fields) do
    OCSF.build_actor(
      app_name: "falco",
      process: normalize_string(output_fields["proc.name"]),
      user: normalize_string(output_fields["user.name"])
    )
  end

  defp build_device(payload, output_fields, device_uid) do
    hostname = falco_device_hostname(payload, output_fields)

    name =
      hostname ||
        normalize_string(output_fields["container.name"]) ||
        normalize_string(output_fields["k8s.pod.name"])

    OCSF.build_device(uid: device_uid || hostname, name: name, hostname: hostname)
  end

  defp falco_device_hostname(payload, output_fields) do
    normalize_string(payload["hostname"]) ||
      normalize_string(output_fields["k8s.node.name"]) ||
      normalize_string(output_fields["host.name"]) ||
      normalize_string(output_fields["evt.hostname"])
  end

  defp falco_device_uid(payload, output_fields, hostname) do
    explicit =
      normalize_string(payload["device_uid"]) ||
        normalize_string(payload["device_id"]) ||
        normalize_string(output_fields["service_radar.device_uid"]) ||
        normalize_string(output_fields["service_radar.device.uid"]) ||
        normalize_string(output_fields["service_radar.device_id"]) ||
        normalize_string(output_fields["serviceradar.device_uid"]) ||
        normalize_string(output_fields["serviceradar.device.uid"]) ||
        normalize_string(output_fields["device_uid"])

    DeviceCorrelation.resolve(%{
      device_uid: explicit,
      agent_id: falco_agent_id(payload, output_fields, hostname),
      hostname: hostname,
      name: normalize_string(output_fields["k8s.node.name"]),
      ip:
        normalize_string(output_fields["service_radar.device_ip"]) ||
          normalize_string(output_fields["service_radar.source_ip"]) ||
          normalize_string(output_fields["serviceradar.device_ip"]) ||
          normalize_string(output_fields["serviceradar.source_ip"]) ||
          normalize_string(output_fields["host.ip"]) ||
          normalize_string(output_fields["evt.host.ip"])
    })
  end

  defp falco_agent_id(payload, output_fields, hostname) do
    normalize_string(payload["agent_id"]) ||
      normalize_string(output_fields["service_radar.agent_id"]) ||
      normalize_string(output_fields["serviceradar.agent_id"]) ||
      normalize_string(output_fields["agent_id"]) ||
      inferred_agent_id(normalize_string(output_fields["k8s.node.name"]) || hostname)
  end

  defp inferred_agent_id(nil), do: nil
  defp inferred_agent_id("agent-" <> _ = agent_id), do: agent_id
  defp inferred_agent_id(hostname), do: "agent-#{hostname}"

  defp resolve_event_id(payload, subject, raw_data) do
    uuid = normalize_string(payload["uuid"])

    if is_binary(uuid) do
      case Ecto.UUID.cast(uuid) do
        {:ok, cast_uuid} -> cast_uuid
        :error -> deterministic_uuid("#{subject}:uuid:#{String.downcase(uuid)}")
      end
    else
      hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
      deterministic_uuid("#{subject}:sha256:#{hash}")
    end
  end

  defp parse_event_time(value, output_fields) do
    cond do
      not is_nil(value) ->
        FieldParser.parse_timestamp(value)

      is_integer(output_fields["evt.time"]) ->
        FieldParser.parse_timestamp(output_fields["evt.time"])

      is_binary(output_fields["evt.time"]) ->
        case Integer.parse(output_fields["evt.time"]) do
          {int, _} -> FieldParser.parse_timestamp(int)
          :error -> @fallback_time
        end

      true ->
        @fallback_time
    end
  end

  defp observed_timestamp(%DateTime{} = received_at, _event_time), do: received_at
  defp observed_timestamp(_received_at, event_time), do: event_time

  defp normalize_subject(subject) when is_binary(subject), do: subject
  defp normalize_subject(_), do: "falco.unknown"

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_tags(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tags(_), do: []

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp maybe_observable(nil, _type, _type_id), do: nil
  defp maybe_observable(value, type, type_id), do: OCSF.build_observable(value, type, type_id)

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
      |> maybe_put("source_kind", "falco")

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
      [:serviceradar, :event_writer, :falco, :dropped],
      %{count: 1},
      %{reason: reason, subject: subject || "falco.unknown"}
    )

    Logger.debug("Dropped Falco message", reason: inspect(reason), subject: subject)
  end
end
