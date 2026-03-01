defmodule ServiceRadar.Observability.MtrConsensusWorker do
  @moduledoc """
  Aggregates MTR command outcomes by incident and emits normalized causal signals.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub

  alias ServiceRadar.Observability.{
    MtrCausalSignalEmitter,
    MtrConsensusEvaluator,
    MtrPolicy
  }

  require Logger

  @default_retention_ms 300_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) do
      AgentCommandPubSub.subscribe()
    end

    emitter = Keyword.get(opts, :emitter, &MtrCausalSignalEmitter.emit/3)
    policy_provider = Keyword.get(opts, :policy_provider, &default_policy_provider/1)
    schedule_cleanup()
    {:ok, %{cohorts: %{}, emitter: emitter, policy_provider: policy_provider}}
  end

  @impl GenServer
  def handle_info({:command_result, data}, state) do
    state =
      if should_process_result?(data) do
        case cohort_key(data) do
          nil ->
            state

          key ->
            process_outcome(key, data, state)
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    cohorts =
      Enum.reduce(state.cohorts, %{}, fn {key, cohort}, acc ->
        if now - cohort.updated_at_ms <= retention_ms() do
          Map.put(acc, key, cohort)
        else
          acc
        end
      end)

    schedule_cleanup()
    {:noreply, %{state | cohorts: cohorts}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_outcome(key, data, state) do
    outcome = outcome_from_result(data)
    context = context_from_result(data)
    policy = select_policy(context, state.policy_provider)

    cohort =
      Map.get(state.cohorts, key, %{
        outcomes: %{},
        context: context,
        policy: policy,
        emitted_identity: nil,
        updated_at_ms: System.monotonic_time(:millisecond)
      })

    outcomes = Map.put(cohort.outcomes, outcome.agent_id, outcome)

    updated = %{
      cohort
      | outcomes: outcomes,
        context: Map.merge(cohort.context, context),
        updated_at_ms: System.monotonic_time(:millisecond)
    }

    outcome_list = Map.values(updated.outcomes)
    consensus_result = MtrConsensusEvaluator.classify(outcome_list, updated.policy)

    emitted_identity =
      maybe_emit_signal(
        consensus_result,
        updated.context,
        outcome_list,
        key,
        updated.emitted_identity,
        state.emitter
      )

    cohorts = Map.put(state.cohorts, key, %{updated | emitted_identity: emitted_identity})
    %{state | cohorts: cohorts}
  end

  defp maybe_emit_signal(consensus_result, context, outcomes, key, emitted_identity, emitter) do
    classification = consensus_result[:classification]

    min_agents =
      (consensus_result[:evidence] || %{}) |> Map.get(:consensus, %{}) |> Map.get(:min_agents, 2)

    enough_data =
      length(outcomes) >= min_agents or
        classification in [:target_outage, :path_scoped_issue, :degraded_path, :healthy]

    if enough_data and classification != :insufficient_evidence do
      identity =
        case context["incident_correlation_id"] || context[:incident_correlation_id] do
          nil -> key
          incident_id -> "incident:#{incident_id}:#{Atom.to_string(classification)}"
        end

      if emitted_identity == identity do
        emitted_identity
      else
        _ = emitter.(consensus_result, context, outcomes)
        identity
      end
    else
      emitted_identity
    end
  end

  defp cohort_key(data) do
    incident_id = get(data, [:incident_correlation_id, "incident_correlation_id"])
    trigger_mode = to_string(get(data, [:trigger_mode, "trigger_mode"]) || "manual")
    command_id = get(data, [:command_id, "command_id"])

    cond do
      incident_id not in [nil, ""] -> "incident:#{incident_id}"
      command_id not in [nil, ""] -> "command:#{trigger_mode}:#{command_id}"
      true -> nil
    end
  end

  defp should_process_result?(data) when is_map(data) do
    to_string(get(data, [:command_type, "command_type"]) || "") == "mtr.run"
  end

  defp should_process_result?(_), do: false

  defp outcome_from_result(data) do
    trace = payload_trace(get(data, [:payload, "payload"]))

    %{
      agent_id: get(data, [:agent_id, "agent_id"]) || "unknown",
      target_reached: trace["target_reached"] == true,
      packet_loss_pct: aggregate_loss_pct(trace),
      avg_rtt_ms: aggregate_avg_rtt_ms(trace),
      path_changed: trace["path_changed"] == true,
      error: trace["error"] || get(data, [:message, "message"]),
      status:
        if(get(data, [:success, "success"]) == true and trace["target_reached"] != false,
          do: "success",
          else: "unreachable"
        ),
      weight: 1.0
    }
  end

  defp context_from_result(data) do
    payload = get(data, [:payload, "payload"]) || %{}
    trace = payload_trace(payload)

    %{
      "incident_correlation_id" =>
        get(data, [:incident_correlation_id, "incident_correlation_id"]),
      "trigger_mode" => get(data, [:trigger_mode, "trigger_mode"]) || "manual",
      "target_device_uid" => get(data, [:target_device_uid, "target_device_uid"]),
      "target_ip" => trace["target_ip"] || payload["target_ip"] || payload["target"],
      "partition_id" => get(data, [:partition_id, "partition_id"]),
      "source_agent_ids" => [get(data, [:agent_id, "agent_id"])]
    }
  end

  defp select_policy(context, provider) do
    case provider.(context) do
      policy when is_map(policy) ->
        policy

      policies when is_list(policies) ->
        choose_policy(policies, context["partition_id"])

      _ ->
        %{}
    end
  end

  defp default_policy_provider(context) do
    partition_id = context["partition_id"]

    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        [choose_policy(policies, partition_id)]

      {:ok, %Ash.Page.Keyset{results: policies}} ->
        [choose_policy(policies, partition_id)]

      _ ->
        []
    end
  end

  defp choose_policy([], _partition_id), do: %{}

  defp choose_policy(policies, partition_id) do
    Enum.find(policies, fn policy ->
      case Map.get(policy, :partition_id) do
        nil -> true
        "" -> true
        ^partition_id -> true
        _ -> false
      end
    end) || hd(policies)
  end

  defp payload_trace(%{"trace" => trace}) when is_map(trace), do: trace
  defp payload_trace(_), do: %{}

  defp aggregate_loss_pct(trace) do
    hops = List.wrap(trace["hops"])

    if hops == [] do
      0.0
    else
      hops
      |> Enum.map(fn hop -> to_float(hop["loss_pct"], 0.0) end)
      |> Enum.max(fn -> 0.0 end)
    end
  end

  defp aggregate_avg_rtt_ms(trace) do
    hops = List.wrap(trace["hops"])

    if hops == [] do
      0.0
    else
      hops
      |> Enum.map(fn hop ->
        cond do
          is_number(hop["avg_rtt_ms"]) -> to_float(hop["avg_rtt_ms"], 0.0)
          is_number(hop["avg_rtt_us"]) -> to_float(hop["avg_rtt_us"], 0.0) / 1000.0
          true -> 0.0
        end
      end)
      |> Enum.max(fn -> 0.0 end)
    end
  end

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value / 1.0
  defp to_float(_value, default), do: default

  defp get(map, keys) when is_map(map) and is_list(keys),
    do: Enum.find_value(keys, fn key -> Map.get(map, key) end)

  defp get(_, _), do: nil

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 60_000)
  end

  defp retention_ms do
    case System.get_env("MTR_CONSENSUS_COHORT_RETENTION_MS") do
      nil ->
        Application.get_env(
          :serviceradar_core,
          :mtr_consensus_cohort_retention_ms,
          @default_retention_ms
        )

      value ->
        parse_int(value, @default_retention_ms)
    end
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default
end
