defmodule ServiceRadar.Observability.StatefulAlertEngine.Diagnostics do
  @moduledoc """
  Accumulating and summarizing diagnostic context for an incident: bounded
  process/container/kubernetes samples, representative source-event ids, the
  latest source record, and the `diagnostic_summary/4` rolled into emitted
  events and incident metadata.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers
  import ServiceRadar.Observability.StatefulAlertEngine.Record

  @diagnostic_sample_limit 5
  @diagnostic_source_limit 10

  def empty_diagnostics do
    %{
      "source_event_ids" => [],
      "samples" => %{
        "processes" => [],
        "containers" => [],
        "kubernetes" => []
      }
    }
  end

  def update_diagnostics(nil, record, now),
    do: update_diagnostics(empty_diagnostics(), record, now)

  def update_diagnostics(diagnostics, record, now) when is_map(diagnostics) do
    context = record_diagnostic_context(record)
    source_event_id = source_event_id(record)
    source = source_record_details(record)

    diagnostics
    |> Map.put_new("source_event_ids", [])
    |> Map.put_new("samples", empty_diagnostics()["samples"])
    |> Map.put("latest_source", source)
    |> update_in(
      ["source_event_ids"],
      &add_bounded_value(&1, source_event_id, @diagnostic_source_limit)
    )
    |> update_in(["samples"], &update_diagnostic_samples(&1, context, now))
  end

  def update_diagnostics(_diagnostics, record, now),
    do: update_diagnostics(empty_diagnostics(), record, now)

  def update_diagnostic_samples(samples, context, now) when is_map(samples) do
    samples
    |> Map.put_new("processes", [])
    |> Map.put_new("containers", [])
    |> Map.put_new("kubernetes", [])
    |> update_in(
      ["processes"],
      &add_bounded_value(&1, process_sample(context, now), @diagnostic_sample_limit)
    )
    |> update_in(
      ["containers"],
      &add_bounded_value(&1, container_sample(context, now), @diagnostic_sample_limit)
    )
    |> update_in(
      ["kubernetes"],
      &add_bounded_value(&1, kubernetes_sample(context, now), @diagnostic_sample_limit)
    )
  end

  def update_diagnostic_samples(_samples, context, now) do
    update_diagnostic_samples(empty_diagnostics()["samples"], context, now)
  end

  def record_diagnostic_context(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)
    signal = map_value(metadata, "security_signal") || %{}
    falco = map_value(unmapped, "falco") || %{}

    diagnostic_payload =
      map_value(signal, "diagnostics") ||
        map_value(falco, "diagnostics") ||
        %{}

    %{
      "rule" => map_value(diagnostic_payload, "rule") || fallback_rule(record),
      "host" => map_value(diagnostic_payload, "host") || fallback_host(record),
      "process" => map_value(diagnostic_payload, "process") || %{},
      "parent_process" => map_value(diagnostic_payload, "parent_process") || %{},
      "container" => map_value(diagnostic_payload, "container") || fallback_container(record),
      "kubernetes" => map_value(diagnostic_payload, "kubernetes") || fallback_kubernetes(record),
      "attribution" => map_value(diagnostic_payload, "attribution") || %{}
    }
  end

  def process_sample(context, now) do
    process = map_value(context, "process") || %{}
    parent = map_value(context, "parent_process") || %{}

    compact_map(%{
      "name" => map_value(process, "name"),
      "parent" => map_value(parent, "name"),
      "command" => map_value(process, "command"),
      "cwd" => map_value(process, "cwd"),
      "executable" => map_value(process, "executable"),
      "executable_flags" => map_value(process, "executable_flags"),
      "observed_at" => iso8601(now)
    })
  end

  def container_sample(context, now) do
    container = map_value(context, "container") || %{}

    compact_map(%{
      "id" => map_value(container, "id"),
      "name" => map_value(container, "name"),
      "image" => map_value(container, "image"),
      "image_repository" => map_value(container, "image_repository"),
      "image_tag" => map_value(container, "image_tag"),
      "observed_at" => iso8601(now)
    })
  end

  def kubernetes_sample(context, now) do
    kubernetes = map_value(context, "kubernetes") || %{}
    attribution = map_value(context, "attribution") || %{}

    compact_map(%{
      "namespace" => map_value(kubernetes, "namespace"),
      "pod" => map_value(kubernetes, "pod"),
      "attribution_status" => map_value(attribution, "status"),
      "missing" => map_value(attribution, "missing"),
      "observed_at" => iso8601(now)
    })
  end

  def diagnostic_summary(rule, snapshot, now, source \\ nil) do
    diagnostics = snapshot.diagnostics || empty_diagnostics()
    first_seen_at = snapshot.first_seen_at || now
    last_seen_at = snapshot.last_seen_at || now
    source = source || Map.get(diagnostics, "latest_source", %{})

    compact_map(%{
      "rule_id" => to_string(rule.id),
      "rule_name" => rule.name,
      "group_key" => snapshot.group_key,
      "group_values" => snapshot.group_values || %{},
      "threshold" => rule.threshold,
      "window_seconds" => rule.window_seconds,
      "bucket_seconds" => rule.bucket_seconds,
      "window_count" => snapshot.window_count || 0,
      "first_seen_at" => iso8601(first_seen_at),
      "last_seen_at" => iso8601(last_seen_at),
      "representative_event_ids" => Map.get(diagnostics, "source_event_ids", []),
      "samples" => Map.get(diagnostics, "samples", %{}),
      "source" => source
    })
  end

  def fallback_rule(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)

    compact_map(%{
      "name" => map_value(metadata, "rule") || map_value(unmapped, "rule"),
      "priority" => map_value(metadata, "priority") || map_value(unmapped, "priority")
    })
  end

  def fallback_host(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)

    compact_map(%{
      "name" => map_value(metadata, "hostname") || map_value(unmapped, "hostname")
    })
  end

  def fallback_container(record) do
    unmapped = event_unmapped(record)
    falco = map_value(unmapped, "falco") || %{}

    compact_map(%{
      "id" => map_value(falco, "container_id") || map_value(unmapped, "container_id"),
      "name" => map_value(falco, "container") || map_value(unmapped, "container")
    })
  end

  def fallback_kubernetes(record) do
    unmapped = event_unmapped(record)
    falco = map_value(unmapped, "falco") || %{}

    compact_map(%{
      "namespace" => map_value(falco, "namespace") || map_value(unmapped, "namespace"),
      "pod" => map_value(falco, "pod") || map_value(unmapped, "pod")
    })
  end

  def source_event_id(record) do
    case fetch_attr(record, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  def add_bounded_value(values, nil, _limit), do: values || []
  def add_bounded_value(values, %{} = value, _limit) when map_size(value) == 0, do: values || []
  def add_bounded_value(values, [] = _value, _limit), do: values || []

  def add_bounded_value(values, value, limit) do
    values = if is_list(values), do: values, else: []

    if Enum.member?(values, value) do
      values
    else
      Enum.take(values ++ [value], limit)
    end
  end
end
