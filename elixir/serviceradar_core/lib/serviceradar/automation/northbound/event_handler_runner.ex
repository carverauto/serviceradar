defmodule ServiceRadar.Automation.Northbound.EventHandlerRunner do
  @moduledoc """
  Evaluates normalized events against enabled northbound action handlers.

  Handlers remain declarative: match expressions decide whether an event applies,
  target resolvers produce device/interface/event target specs, and input
  templates render the action input payload. Actual execution still goes through
  `InvocationService`, so user launches, scheduled launches, and event-driven
  launches share the same audit and dispatch path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionEventHandler
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query
  require Logger

  @type outcome ::
          :ignored
          | :suppressed
          | :pending_approval
          | :dry_run
          | :dispatched
          | :failed

  @spec handle_event(map() | struct(), keyword()) :: {:ok, [map()]}
  def handle_event(event, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:northbound_event_handler))
    handlers = Keyword.get_lazy(opts, :handlers, fn -> list_enabled_handlers(actor) end)
    context = event_context(event)

    results =
      Enum.map(handlers, fn handler ->
        handle_event_with_handler(handler, context, actor, opts)
      end)

    {:ok, results}
  end

  @spec handle_event_with_handler(map() | ActionEventHandler.t(), map(), map(), keyword()) ::
          map()
  def handle_event_with_handler(handler, context, actor, opts \\ []) do
    if event_matches?(handler_match_expression(handler), context) do
      maybe_invoke_handler(handler, context, actor, opts)
    else
      result(handler, :ignored, :not_matched)
    end
  rescue
    exception ->
      reason = Exception.format(:error, exception, __STACKTRACE__)
      emit_handler_event(:failed, handler, context, %{error: reason}, actor, opts)
      result(handler, :failed, reason)
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)
      emit_handler_event(:failed, handler, context, %{error: formatted}, actor, opts)
      result(handler, :failed, formatted)
  end

  defp maybe_invoke_handler(handler, context, actor, opts) do
    dedupe_key = render_template(handler_dedupe_template(handler), context)

    case suppression_reason(handler, dedupe_key, opts) do
      nil ->
        invoke_handler(handler, context, dedupe_key, actor, opts)

      reason ->
        emit_handler_event(:suppressed, handler, context, %{reason: reason}, actor, opts)
        result(handler, :suppressed, reason)
    end
  end

  defp invoke_handler(handler, context, dedupe_key, actor, opts) do
    attrs = invocation_attrs(handler, context, dedupe_key)

    case handler_approval_mode(handler) do
      :automatic ->
        create_and_dispatch(handler, attrs, dedupe_key, actor, opts)

      :dry_run ->
        create_dry_run(handler, attrs, dedupe_key, actor, opts)

      _manual ->
        create_pending_approval(handler, attrs, dedupe_key, actor, opts)
    end
  end

  defp create_and_dispatch(handler, attrs, dedupe_key, actor, opts) do
    create_and_dispatch =
      Keyword.get(opts, :create_and_dispatch, &InvocationService.create_and_dispatch/2)

    case create_and_dispatch.(attrs, actor: actor) do
      {:ok, invocation} ->
        record_triggered(handler, dedupe_key, actor)

        emit_handler_event(
          :execution,
          handler,
          attrs,
          invocation_metadata(invocation),
          actor,
          opts
        )

        result(handler, :dispatched, :automatic, invocation)

      {:error, reason} ->
        emit_handler_event(:failed, handler, attrs, %{error: inspect(reason)}, actor, opts)
        result(handler, :failed, reason)
    end
  end

  defp create_pending_approval(handler, attrs, dedupe_key, actor, opts) do
    create_invocation =
      Keyword.get(opts, :create_invocation, &InvocationService.create_invocation/2)

    attrs =
      put_in(attrs, [:metadata], Map.put(attrs.metadata, "approval_required", true))

    case create_invocation.(attrs, actor: actor) do
      {:ok, invocation} ->
        record_triggered(handler, dedupe_key, actor)

        emit_handler_event(
          :approval,
          handler,
          attrs,
          invocation_metadata(invocation),
          actor,
          opts
        )

        result(handler, :pending_approval, :manual_approval_required, invocation)

      {:error, reason} ->
        emit_handler_event(:failed, handler, attrs, %{error: inspect(reason)}, actor, opts)
        result(handler, :failed, reason)
    end
  end

  defp create_dry_run(handler, attrs, dedupe_key, actor, opts) do
    create_invocation =
      Keyword.get(opts, :create_invocation, &InvocationService.create_invocation/2)

    attrs =
      put_in(attrs, [:metadata], Map.put(attrs.metadata, "dry_run", true))

    case create_invocation.(attrs, actor: actor) do
      {:ok, invocation} ->
        record_triggered(handler, dedupe_key, actor)
        suppress_invocation(invocation, actor)

        emit_handler_event(
          :suppressed,
          handler,
          attrs,
          invocation_metadata(invocation),
          actor,
          opts
        )

        result(handler, :dry_run, :dry_run, invocation)

      {:error, reason} ->
        emit_handler_event(:failed, handler, attrs, %{error: inspect(reason)}, actor, opts)
        result(handler, :failed, reason)
    end
  end

  defp invocation_attrs(handler, context, dedupe_key) do
    event_id = context_value(context, "event.id") || context_value(context, "event.event_id")

    metadata =
      reject_nil_values(%{
        "event_handler_name" => handler_value(handler, :name),
        "dedupe_key" => dedupe_key,
        "event_summary" => event_summary(context)
      })

    %{
      descriptor_id: handler_value(handler, :descriptor_id),
      event_handler_id: handler_value(handler, :id),
      originating_event_id: event_id,
      source: :event_handler,
      targets: render_targets(handler_target_resolver(handler), context),
      input_values: render_template(handler_input_template(handler), context),
      metadata: metadata
    }
  end

  defp render_targets(%{} = resolver, context) do
    targets =
      case fetch(resolver, :targets) do
        targets when is_list(targets) -> targets
        _ -> [resolver]
      end

    targets
    |> Enum.map(&render_template(&1, context))
    |> Enum.map(&normalize_target/1)
    |> Enum.reject(&is_nil/1)
  end

  defp render_targets(_resolver, _context), do: []

  defp normalize_target(%{} = target) do
    target = stringify_keys(target)
    kind = normalize_string(target["kind"]) || infer_target_kind(target)

    if is_nil(kind) do
      nil
    else
      Map.put(target, "kind", kind)
    end
  end

  defp normalize_target(_target), do: nil

  defp infer_target_kind(target) do
    cond do
      present?(target["interface_uid"]) -> "interface"
      present?(target["device_uid"]) -> "device"
      present?(target["event_id"]) -> "event"
      true -> nil
    end
  end

  defp suppression_reason(handler, dedupe_key, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cooldown_seconds = handler_cooldown_seconds(handler)

    cond do
      cooldown_seconds <= 0 ->
        nil

      within_cooldown?(handler_value(handler, :last_triggered_at), cooldown_seconds, now) ->
        :cooldown

      present?(dedupe_key) and dedupe_key == last_dedupe_key(handler) and
          within_cooldown?(last_dedupe_at(handler), cooldown_seconds, now) ->
        :dedupe

      true ->
        nil
    end
  end

  defp within_cooldown?(nil, _cooldown_seconds, _now), do: false

  defp within_cooldown?(timestamp, cooldown_seconds, now) do
    case normalize_datetime(timestamp) do
      nil -> false
      timestamp -> DateTime.diff(now, timestamp, :second) < cooldown_seconds
    end
  end

  defp record_triggered(%ActionEventHandler{} = handler, dedupe_key, actor) do
    metadata =
      handler
      |> handler_metadata()
      |> Map.put("last_dedupe_key", dedupe_key)
      |> Map.put(
        "last_dedupe_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    handler
    |> Ash.Changeset.for_update(:record_triggered, %{metadata: metadata}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
  rescue
    exception ->
      Logger.warning("Failed to record northbound event handler trigger",
        handler_id: handler_value(handler, :id),
        reason: Exception.message(exception)
      )

      {:error, exception}
  end

  defp record_triggered(handler, _dedupe_key, _actor), do: {:ok, handler}

  defp suppress_invocation(%ActionInvocation{} = invocation, actor) do
    ActionInvocation.record_suppressed(
      invocation,
      %{
        result_summary: %{"status" => "dry_run"},
        error_class: "dry_run",
        error_message: "Event handler is configured for dry run"
      },
      actor: actor
    )
  end

  defp suppress_invocation(_invocation, _actor), do: :ok

  defp event_matches?(expression, context)
  defp event_matches?(expression, _context) when expression in [nil, %{}, []], do: true

  defp event_matches?(%{"all" => expressions}, context) when is_list(expressions),
    do: Enum.all?(expressions, &event_matches?(&1, context))

  defp event_matches?(%{"any" => expressions}, context) when is_list(expressions),
    do: Enum.any?(expressions, &event_matches?(&1, context))

  defp event_matches?(%{"not" => expression}, context),
    do: not event_matches?(expression, context)

  defp event_matches?(%{"field" => field} = expression, context) when is_binary(field) do
    value = context_value(context, field)

    cond do
      Map.has_key?(expression, "equals") ->
        comparable(value) == comparable(expression["equals"])

      Map.has_key?(expression, "in") ->
        comparable(value) in Enum.map(List.wrap(expression["in"]), &comparable/1)

      Map.has_key?(expression, "contains") ->
        contains?(value, expression["contains"])

      Map.has_key?(expression, "exists") ->
        not is_nil(value) == truthy?(expression["exists"])

      Map.has_key?(expression, "matches") ->
        regex_match?(value, expression["matches"])

      true ->
        present?(value)
    end
  end

  defp event_matches?(%{} = expression, context) do
    Enum.all?(expression, fn {field, expected} ->
      comparable(context_value(context, to_string(field))) == comparable(expected)
    end)
  end

  defp event_matches?(_expression, _context), do: false

  defp contains?(values, expected) when is_list(values),
    do: comparable(expected) in Enum.map(values, &comparable/1)

  defp contains?(value, expected) when is_binary(value),
    do: String.contains?(String.downcase(value), String.downcase(to_string(expected)))

  defp contains?(_value, _expected), do: false

  defp regex_match?(value, pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, to_string(value || ""))
      {:error, _} -> false
    end
  end

  defp regex_match?(_value, _pattern), do: false

  defp render_template(nil, _context), do: nil

  defp render_template(value, context) when is_binary(value) do
    case Regex.run(~r/^\{\{\s*([^}]+?)\s*\}\}$/, value) do
      [_, path] ->
        context_value(context, String.trim(path))

      _ ->
        Regex.replace(~r/\{\{\s*([^}]+?)\s*\}\}/, value, fn _match, path ->
          context
          |> context_value(String.trim(path))
          |> case do
            nil -> ""
            rendered -> to_string(rendered)
          end
        end)
    end
  end

  defp render_template(%{} = map, context) do
    Map.new(map, fn {key, value} -> {key, render_template(value, context)} end)
  end

  defp render_template(values, context) when is_list(values),
    do: Enum.map(values, &render_template(&1, context))

  defp render_template(value, _context), do: value

  defp event_context(event) do
    event_map = normalize_event(event)

    %{
      "event" => event_map,
      "metadata" => normalize_map(fetch(event_map, :metadata)),
      "device" => normalize_map(fetch(event_map, :device)),
      "src_endpoint" => normalize_map(fetch(event_map, :src_endpoint)),
      "dst_endpoint" => normalize_map(fetch(event_map, :dst_endpoint)),
      "unmapped" => normalize_map(fetch(event_map, :unmapped))
    }
  end

  defp normalize_event(%_{} = event) do
    event
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
    |> stringify_keys()
  end

  defp normalize_event(%{} = event), do: stringify_keys(event)
  defp normalize_event(_event), do: %{}

  defp context_value(context, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while(context, fn key, acc ->
      case fetch(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp context_value(_context, _path), do: nil

  defp list_enabled_handlers(actor) do
    case ActionEventHandler.list_enabled(actor: actor) do
      {:ok, handlers} -> handlers
      _ -> []
    end
  end

  defp emit_handler_event(kind, handler, context_or_attrs, details, actor, opts) do
    attrs = handler_event_attrs(kind, handler, context_or_attrs, details)

    case Keyword.get(opts, :emit_event, &record_ocsf_event/2).(attrs, actor) do
      {:ok, _event} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("northbound handler event was not recorded: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  defp record_ocsf_event(attrs, actor) do
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create(actor: actor, domain: ServiceRadar.Monitoring)
  end

  defp handler_event_attrs(kind, handler, context_or_attrs, details) do
    class_uid = OCSF.class_event_log_activity()
    activity_id = OCSF.activity_log_create()
    {status_id, status, severity_id} = event_status(kind)

    %{
      time: DateTime.utc_now(),
      class_uid: class_uid,
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(class_uid, activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: "Northbound event handler #{kind}",
      status_id: status_id,
      status: status,
      metadata:
        reject_nil_values(%{
          "event_family" => "northbound_action_handler",
          "event_kind" => to_string(kind),
          "handler_id" => handler_value(handler, :id),
          "handler_name" => handler_value(handler, :name),
          "descriptor_id" => handler_value(handler, :descriptor_id),
          "source_event_id" => source_event_id(context_or_attrs),
          "details" => stringify_keys(details)
        })
    }
  end

  defp event_status(:failed),
    do: {OCSF.status_failure(), OCSF.status_name(OCSF.status_failure()), OCSF.severity_high()}

  defp event_status(_kind),
    do:
      {OCSF.status_success(), OCSF.status_name(OCSF.status_success()),
       OCSF.severity_informational()}

  defp source_event_id(%{originating_event_id: id}) when is_binary(id), do: id
  defp source_event_id(%{"event" => event}), do: fetch(event, :id) || fetch(event, :event_id)
  defp source_event_id(_value), do: nil

  defp result(handler, status, reason, invocation \\ nil) do
    %{
      handler_id: handler_value(handler, :id),
      handler_name: handler_value(handler, :name),
      status: status,
      reason: reason,
      invocation_id: invocation_id(invocation)
    }
  end

  defp invocation_metadata(invocation) do
    reject_nil_values(%{
      invocation_id: invocation_id(invocation),
      invocation_state: handler_value(invocation, :state)
    })
  end

  defp invocation_id(%{id: id}) when is_binary(id), do: id
  defp invocation_id(_invocation), do: nil

  defp event_summary(%{"event" => event}) do
    reject_nil_values(%{
      "id" => fetch(event, :id),
      "severity" => fetch(event, :severity),
      "message" => fetch(event, :message)
    })
  end

  defp event_summary(_context), do: %{}

  defp handler_match_expression(handler),
    do: handler |> handler_value(:match_expression) |> normalize_map()

  defp handler_target_resolver(handler),
    do: handler |> handler_value(:target_resolver) |> normalize_map()

  defp handler_input_template(handler),
    do: handler |> handler_value(:input_template) |> normalize_map()

  defp handler_dedupe_template(handler), do: handler_value(handler, :dedupe_key_template)
  defp handler_metadata(handler), do: handler |> handler_value(:metadata) |> normalize_map()

  defp handler_cooldown_seconds(handler) do
    case handler_value(handler, :cooldown_seconds) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> 300
        end

      _ ->
        300
    end
  end

  defp handler_approval_mode(handler) do
    case handler_value(handler, :approval_mode) do
      value when value in [:automatic, :manual, :dry_run] -> value
      "automatic" -> :automatic
      "dry_run" -> :dry_run
      _ -> :manual
    end
  end

  defp last_dedupe_key(handler), do: handler |> handler_metadata() |> fetch(:last_dedupe_key)
  defp last_dedupe_at(handler), do: handler |> handler_metadata() |> fetch(:last_dedupe_at)

  defp handler_value(map, key), do: fetch(map, key)

  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp fetch(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp fetch(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch(_map, _key), do: nil

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_nested(%{} = value), do: stringify_keys(value)
  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp normalize_map(%{} = value), do: stringify_keys(value)
  defp normalize_map(_value), do: %{}

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp comparable(value) when is_binary(value), do: String.downcase(value)
  defp comparable(value), do: value

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
