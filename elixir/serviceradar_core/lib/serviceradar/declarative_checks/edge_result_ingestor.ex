defmodule ServiceRadar.DeclarativeChecks.EdgeResultIngestor do
  @moduledoc """
  Ingests `io.serviceradar.declarative-check-runner` `serviceradar.plugin_result.v1`
  payloads carrying `serviceradar.declarative_check_edge_result.v1` details (`3.4`).

  Arriving via agent `RecordSpool` -> gateway -> JetStream -> `PluginResultIngestor`:
  1. Upserts redacted, bounded (`<= 16_384` bytes) `DeclarativeCheckEdgeObservation`
     rows keyed by `(check_id, node_id, target_key, host_authenticated_agent_id)`.
  2. For pure single-agent Edge checks, directly updates `DeclarativeCheckInstance`,
     projects `ServiceState` (`ServiceStateProjector`), and publishes OCSF
     `health.state_change` transitions (`VerdictEventWriter`).
  3. For Hybrid checks or multi-agent Edge checks, triggers debounced
     `CoreEvaluationWorker.schedule_debounced_hybrid_refresh/1` DAG evaluation.
  """

  @behaviour ServiceRadar.Observability.PluginResultHandler

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.SecretTextScrubber
  alias ServiceRadar.DeclarativeChecks.AssignmentCompiler
  alias ServiceRadar.DeclarativeChecks.CoreEvaluationWorker
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.DeclarativeChecks.ServiceStateProjector
  alias ServiceRadar.DeclarativeChecks.VerdictEventWriter
  alias ServiceRadar.Observability.PluginResultHandlerOutcome

  require Logger

  @edge_result_schema "serviceradar.declarative_check_edge_result.v1"
  @max_targets 1_000
  @max_observations_per_target 64
  @max_json_bytes 16_000
  @system_actor SystemActor.system(:declarative_check_edge_ingestor)

  @refused_reasons [
    :declarative_check_invalid_edge_result,
    :declarative_check_missing_agent_id,
    :declarative_check_too_many_targets
  ]

  @settled_reasons [
    :declarative_check_inactive_or_deleted
  ]

  @impl true
  def settled_reasons, do: @settled_reasons

  @impl true
  def refused_reasons, do: @refused_reasons

  @doc "Canonical JSON schema identifier for Edge declarative check result details."
  @spec schema() :: String.t()
  def schema, do: @edge_result_schema

  @impl true
  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload),
    do: Enum.any?(payload, &supports?(&1, status))

  ## Envelope Processing
  def supports?(payload, _status) when is_map(payload) do
    details = decode_details(payload)
    Map.get(details, "schema") == @edge_result_schema
  end

  def supports?(_payload, _status), do: false

  @impl true
  @spec ingest(map() | list(), map(), keyword()) :: PluginResultHandlerOutcome.t()
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.filter(&supports?(&1, status))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case ingest(item, status, opts) do
        :ok -> {:cont, :ok}
        {:settled, _reason, _meta} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  def ingest(payload, status, opts) when is_map(payload) do
    actor = Keyword.get(opts, :actor, @system_actor)
    details = decode_details(payload)

    with {:ok, agent_id} <- extract_authenticated_agent_id(status),
         {:ok, envelope} <- validate_envelope(details) do
      process_envelope(envelope, agent_id, payload, status, actor, opts)
    else
      {:error, reason} when reason in @refused_reasons ->
        {:refused, reason, %{agent_id: raw_agent_id(status)}}
    end
  end

  defp process_envelope(envelope, agent_id, payload, status, actor, opts) do
    case load_active_check(envelope.check_id, actor, opts) do
      {:ok, check} ->
        fallback_now = resolve_observed_at(envelope.observed_at, payload, status)

        with :ok <-
               persist_all_observations(
                 check,
                 envelope.targets,
                 agent_id,
                 fallback_now,
                 actor,
                 opts
               ) do
          dispatch_post_observation(check, envelope, fallback_now, actor, opts)
        end

      :inactive_or_missing ->
        {:settled, :declarative_check_inactive_or_deleted,
         %{check_id: envelope.check_id, agent_id: agent_id}}

      {:error, reason} ->
        {:error, {:declarative_check_lookup_failed, reason}}
    end
  end

  defp persist_all_observations(check, targets, agent_id, fallback_now, actor, opts) do
    check_id = to_string(fetch_val(check, :id))

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      obs_list = Enum.take(target.edge_observations, @max_observations_per_target)

      case persist_target_observations(
             check_id,
             target,
             obs_list,
             agent_id,
             fallback_now,
             actor,
             opts
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp persist_target_observations(
         check_id,
         target,
         obs_list,
         agent_id,
         fallback_now,
         actor,
         opts
       ) do
    Enum.reduce_while(obs_list, :ok, fn obs, :ok ->
      attrs = %{
        check_id: check_id,
        node_id: obs.node_id,
        target_key: target.target_key,
        device_uid: target.device_uid,
        agent_id: agent_id,
        status: obs.status,
        value: obs.value,
        payload: bound_json_map(scrub_term(obs.payload)),
        duration_ms: obs.duration_ms,
        observed_at: obs.observed_at || fallback_now
      }

      case upsert_observation(attrs, actor, opts) do
        {:ok, _record} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:edge_observation_upsert_failed, reason}}}
      end
    end)
  end

  defp dispatch_post_observation(check, envelope, evaluated_at, actor, opts) do
    nodes = fetch_val(check, :nodes, [])
    topology = SchemaValidator.classify_topology(nodes)

    pure_single_edge? =
      topology == :edge_only and AssignmentCompiler.single_agent_edge_only?(check)

    if pure_single_edge? and envelope.single_agent_complete do
      apply_direct_edge_verdicts(check, envelope.targets, evaluated_at, actor, opts)
    else
      trigger_hybrid_evaluation(check, opts)
    end
  end

  defp apply_direct_edge_verdicts(check, targets, evaluated_at, actor, opts) do
    check_id = to_string(fetch_val(check, :id))

    result =
      Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, transitions_acc} ->
        case upsert_direct_instance_and_project(
               check,
               check_id,
               target,
               evaluated_at,
               actor,
               opts
             ) do
          {:ok, nil} -> {:cont, {:ok, transitions_acc}}
          {:ok, transition} -> {:cont, {:ok, [transition | transitions_acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, transitions_rev} ->
        transitions = Enum.reverse(transitions_rev)

        if transitions != [] and Keyword.get(opts, :emit_events?, true) do
          VerdictEventWriter.write_transitions(check, transitions, opts)
        end

        :ok

      {:error, _} = err ->
        err
    end
  end

  defp upsert_direct_instance_and_project(check, check_id, target, evaluated_at, actor, opts) do
    existing = fetch_existing_instance(check_id, target.target_key, actor, opts)

    prev_verdict = existing && to_string(fetch_val(existing, :verdict))
    prev_status = existing && normalize_status_atom(fetch_val(existing, :status))

    transitioned? =
      is_nil(existing) or prev_verdict != target.verdict or prev_status != target.status

    changed_at =
      if transitioned? do
        evaluated_at
      else
        fetch_val(existing, :changed_at) || evaluated_at
      end

    summary = scrub_text(target.summary || "#{fetch_val(check, :slug)}: #{target.verdict}")
    bounded_snapshots = bound_json_map(scrub_term(target.node_snapshots))

    instance_attrs = %{
      check_id: check_id,
      target_key: target.target_key,
      target_kind: target.target_kind,
      device_uid: target.device_uid,
      service_target_id: target.service_target_id,
      verdict: scrub_text(target.verdict),
      status: target.status,
      summary: String.slice(summary, 0, 512),
      node_snapshots: bounded_snapshots,
      evaluated_at: evaluated_at,
      changed_at: changed_at
    }

    with {:ok, persisted} <- upsert_instance(instance_attrs, actor, opts) do
      _ = ServiceStateProjector.project_instance(check, persisted, opts)

      ## Validation & Persistence Adapters

      if transitioned? do
        {:ok,
         %{
           target_key: target.target_key,
           device_uid: target.device_uid,
           service_target_id: target.service_target_id,
           from_verdict: prev_verdict,
           to_verdict: instance_attrs.verdict,
           from_status: prev_status,
           to_status: target.status,
           summary: instance_attrs.summary,
           evaluated_at: evaluated_at
         }}
      else
        {:ok, nil}
      end
    end
  end

  defp trigger_hybrid_evaluation(check, opts) do
    check_id = to_string(fetch_val(check, :id))

    case Keyword.get(opts, :hybrid_refresher) do
      fun when is_function(fun, 1) ->
        _ = fun.(check_id)
        :ok

      _ ->
        case CoreEvaluationWorker.schedule_debounced_hybrid_refresh(check_id) do
          {:ok, _job} ->
            :ok

          {:error, :oban_unavailable} ->
            Logger.debug(
              "Oban unavailable during hybrid Edge observation ingest for check #{check_id}"
            )

            :ok

          {:error, reason} ->
            {:error, {:hybrid_refresh_enqueue_failed, reason}}
        end
    end
  end

  defp validate_envelope(%{"schema" => @edge_result_schema} = details) do
    check_id = non_empty_str(details["check_id"])
    raw_targets = details["targets"]

    cond do
      not valid_uuid?(check_id) ->
        {:error, :declarative_check_invalid_edge_result}

      not is_list(raw_targets) ->
        {:error, :declarative_check_invalid_edge_result}

      length(raw_targets) > @max_targets ->
        {:error, :declarative_check_too_many_targets}

      true ->
        case normalize_targets(raw_targets) do
          {:ok, targets} ->
            {:ok,
             %{
               check_id: check_id,
               slug: non_empty_str(details["slug"]),
               topology: non_empty_str(details["topology"]) || "edge_only",
               single_agent_complete: details["single_agent_complete"] == true,
               observed_at: parse_datetime(details["observed_at"]),
               targets: targets
             }}

          :error ->
            {:error, :declarative_check_invalid_edge_result}
        end
    end
  end

  defp validate_envelope(_), do: {:error, :declarative_check_invalid_edge_result}

  defp normalize_targets(raw_targets) do
    raw_targets
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case normalize_single_target(raw) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  defp normalize_single_target(raw) when is_map(raw) do
    target_key = non_empty_str(raw["target_key"]) || "singleton"
    target_kind = normalize_target_kind(raw["target_kind"], target_key)
    status = normalize_status_atom(raw["status"])
    verdict = non_empty_str(raw["verdict"]) || Atom.to_string(status)
    raw_obs = Map.get(raw, "edge_observations", [])

    if is_list(raw_obs) and byte_size(target_key) <= 255 do
      observations = Enum.flat_map(raw_obs, &normalize_observation/1)

      {:ok,
       %{
         target_key: target_key,
         target_kind: target_kind,
         device_uid: non_empty_str(raw["device_uid"]),
         service_target_id: non_empty_str(raw["service_target_id"]),
         status: status,
         verdict: verdict,
         summary: non_empty_str(raw["summary"]),
         node_snapshots: stringify_map(Map.get(raw, "node_snapshots", %{})),
         edge_observations: observations
       }}
    else
      :error
    end
  end

  defp normalize_single_target(_), do: :error

  defp normalize_observation(raw) when is_map(raw) do
    node_id = non_empty_str(raw["node_id"])

    if is_binary(node_id) and byte_size(node_id) <= 128 do
      dur =
        case raw["duration_ms"] do
          n when is_integer(n) and n >= 0 -> n
          n when is_float(n) and n >= 0 -> trunc(n)
          _ -> 0
        end

      [
        %{
          node_id: node_id,
          status: normalize_status_atom(raw["status"]),
          value: non_empty_str(raw["value"]),
          duration_ms: dur,
          observed_at: parse_datetime(raw["observed_at"]),
          payload: stringify_map(Map.get(raw, "payload", %{}))
        }
      ]
    else
      []
    end
  end

  defp normalize_observation(_), do: []

  defp load_active_check(check_id, actor, opts) do
    case Keyword.get(opts, :check_loader) do
      loader when is_function(loader, 1) ->
        case loader.(check_id) do
          {:ok, %{state: state} = check} when state in [:enabled, "enabled"] -> {:ok, check}
          {:ok, _inactive} -> :inactive_or_missing
          :not_found -> :inactive_or_missing
          {:error, :not_found} -> :inactive_or_missing
          {:error, reason} -> {:error, reason}
        end

      ## Helpers
      _ ->
        case DeclarativeCheck.get_by_id(check_id, actor: actor) do
          {:ok, %{state: :enabled} = check} ->
            {:ok, check}

          {:ok, _disabled_or_nil} ->
            :inactive_or_missing

          {:error, %Ash.Error.Invalid{errors: [%NotFound{} | _]}} ->
            :inactive_or_missing

          {:error, %NotFound{}} ->
            :inactive_or_missing

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp upsert_observation(attrs, actor, opts) do
    case Keyword.get(opts, :observation_upserter) do
      fun when is_function(fun, 1) ->
        fun.(attrs)

      _ ->
        DeclarativeCheckEdgeObservation.upsert_observation(attrs, actor: actor)
    end
  end

  defp fetch_existing_instance(check_id, target_key, actor, opts) do
    case Keyword.get(opts, :instance_loader) do
      fun when is_function(fun, 2) ->
        fun.(check_id, target_key)

      _ ->
        case DeclarativeCheckInstance.get_by_check_target(check_id, target_key, actor: actor) do
          {:ok, %DeclarativeCheckInstance{} = inst} -> inst
          _ -> nil
        end
    end
  end

  defp upsert_instance(attrs, actor, opts) do
    case Keyword.get(opts, :instance_upserter) do
      fun when is_function(fun, 1) ->
        fun.(attrs)

      _ ->
        DeclarativeCheckInstance.upsert_instance(attrs, actor: actor)
    end
  end

  defp extract_authenticated_agent_id(status) do
    case raw_agent_id(status) do
      nil -> {:error, :declarative_check_missing_agent_id}
      agent_id -> {:ok, agent_id}
    end
  end

  defp raw_agent_id(status) when is_map(status) do
    non_empty_str(Map.get(status, :agent_id) || Map.get(status, "agent_id"))
  end

  defp raw_agent_id(_), do: nil

  defp decode_details(payload) when is_map(payload) do
    case Map.get(payload, "details") || Map.get(payload, :details) do
      details when is_map(details) ->
        stringify_map(details)

      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp resolve_observed_at(%DateTime{} = dt, _payload, _status),
    do: DateTime.truncate(dt, :microsecond)

  defp resolve_observed_at(_, payload, status) do
    parse_datetime(Map.get(payload, "observed_at") || Map.get(payload, :observed_at)) ||
      parse_datetime(Map.get(status, "observed_at") || Map.get(status, :observed_at)) ||
      DateTime.truncate(DateTime.utc_now(), :microsecond)
  end

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(String.trim(raw)) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp normalize_status_atom(s) when s in [:healthy, :degraded, :down, :unknown], do: s

  defp normalize_status_atom(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      v when v in ["healthy", "ok", "up", "passed"] -> :healthy
      v when v in ["degraded", "warning", "warn"] -> :degraded
      v when v in ["down", "critical", "crit", "failed", "error"] -> :down
      _ -> :unknown
    end
  end

  defp normalize_status_atom(_), do: :unknown

  defp normalize_target_kind(kind, target_key) do
    case to_string(kind || "") do
      "device" ->
        :device

      "service_target" ->
        :service_target

      "singleton" ->
        :singleton

      _ ->
        cond do
          String.starts_with?(target_key, "device:") -> :device
          String.starts_with?(target_key, "service:") -> :service_target
          true -> :singleton
        end
    end
  end

  defp scrub_term(term) when is_map(term) do
    term
    |> CredentialRedactor.redact()
    |> Map.new(fn {k, v} -> {to_string(k), scrub_nested(v)} end)
  end

  defp scrub_term(_), do: %{}

  defp scrub_nested(v) when is_map(v), do: scrub_term(v)
  defp scrub_nested(v) when is_list(v), do: Enum.map(v, &scrub_nested/1)
  defp scrub_nested(v) when is_binary(v), do: scrub_text(v)
  defp scrub_nested(v), do: v

  defp scrub_text(s) when is_binary(s) do
    s
    |> SecretTextScrubber.scrub_text()
    |> then(&Regex.replace(~r/\b(Bearer|Basic|Token)\s+[^\s,}\]"']+/i, &1, "\\1 [REDACTED]"))
  end

  defp scrub_text(other), do: to_string(other || "")

  defp bound_json_map(map) when is_map(map) do
    encoded = Jason.encode!(map)

    if byte_size(encoded) <= @max_json_bytes do
      map
    else
      slim =
        Map.new(map, fn {k, v} ->
          case v do
            %{} = nested ->
              {k,
               %{
                 "status" => Map.get(nested, "status"),
                 "verdict" => Map.get(nested, "verdict"),
                 "truncated" => true
               }}

            _ ->
              {k, "[truncated]"}
          end
        end)

      if byte_size(Jason.encode!(slim)) <= @max_json_bytes do
        slim
      else
        %{"_truncated" => true}
      end
    end
  end

  defp valid_uuid?(s) when is_binary(s) do
    Regex.match?(
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
      s
    )
  end

  defp valid_uuid?(_), do: false

  defp stringify_map(map) when is_struct(map), do: map |> Map.from_struct() |> stringify_map()

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) ->
        {to_string(k), stringify_map(v)}

      {k, v} when is_list(v) ->
        {to_string(k), Enum.map(v, &if(is_map(&1), do: stringify_map(&1), else: &1))}

      {k, v} ->
        {to_string(k), v}
    end)
  end

  defp stringify_map(_), do: %{}

  defp fetch_val(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end

  defp non_empty_str(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_str(_), do: nil
end
