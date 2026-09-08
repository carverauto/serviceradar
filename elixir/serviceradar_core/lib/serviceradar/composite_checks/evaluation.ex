defmodule ServiceRadar.CompositeChecks.Evaluation do
  @moduledoc """
  Runs one evaluation pass for a composite check.

  Per page of the scope, exactly one availability query and one device-metadata
  query are issued; resolution and evaluation happen in memory, because the
  resolvers and the evaluator are pure. That is what keeps a pass over a large
  scope from becoming an N+1.

  Scope exit is handled by mark-and-sweep rather than by diffing UID sets: every
  row written in a pass carries the pass start time in `evaluated_at`, and rows
  older than that at the end of the pass belonged to devices that are no longer
  in scope. Memory stays bounded no matter how large the scope is.

  A pass that did not complete never sweeps. Un-evaluated rows keep an older
  `evaluated_at` and would be indistinguishable from devices that left the
  scope, so sweeping after a partial failure would delete verdicts for devices
  that are still perfectly in scope. This is enforced by letting the failure
  propagate: `Scope.stream_uids/2` raises on a query error, so `run/2` never
  reaches the sweep and Oban retries the pass. Do not "improve" this by
  rescuing mid-pass and continuing — the sweep would then run against a partial
  evaluation and delete live verdicts.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluator
  alias ServiceRadar.CompositeChecks.Resolvers
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  require Logger

  @type transition :: %{
          device_uid: String.t(),
          check_id: Ash.UUID.t(),
          from_verdict: String.t() | nil,
          to_verdict: String.t(),
          from_status: atom() | nil,
          to_status: atom(),
          inputs: map()
        }

  @type summary :: %{
          evaluated: non_neg_integer(),
          transitions: [transition()],
          removed: non_neg_integer()
        }

  @spec run(struct(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    started_at = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- Scope.normalize(check.scope_query),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check.id, actor: actor) do
      {evaluated, transitions} =
        run_pages(check, normalized, inputs, rules, started_at, actor, opts)

      # Only reached when every page succeeded; a page failure raises out of
      # run_pages/7 above and leaves existing verdicts untouched.
      removed = sweep_out_of_scope(check, started_at)

      # Opt-out exists so the authoring preview can reuse the pass without
      # polluting the event stream. Defaults on, so production needs no opt-in.
      if Keyword.get(opts, :emit_events?, true) do
        VerdictEventWriter.write_transitions(check, transitions)
      end

      {:ok, %{evaluated: evaluated, transitions: transitions, removed: removed}}
    end
  end

  defp run_pages(check, normalized, inputs, rules, started_at, actor, opts) do
    normalized
    |> Scope.stream_uids(opts)
    |> Enum.reduce({0, []}, fn uids, {count, acc} ->
      {:ok, rows} = evaluate_devices(check, inputs, rules, uids, opts)
      persist_canonical_availability(check, rows, actor)
      {count + length(rows), acc ++ persist_page(check, rows, started_at, actor)}
    end)
  end

  @doc """
  Resolves inputs and evaluates verdicts for a set of device UIDs without
  persisting anything.

  The authoring preview calls this directly, which is what guarantees preview
  and production cannot disagree.
  """
  @spec evaluate_devices(struct(), [struct()], [struct()], [String.t()], keyword()) ::
          {:ok, [map()]}
  def evaluate_devices(check, inputs, rules, uids, opts \\ [])

  def evaluate_devices(_check, _inputs, _rules, [], _opts), do: {:ok, []}

  def evaluate_devices(check, inputs, rules, uids, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    availability = load_availability(inputs, uids)
    metadata = load_metadata(inputs, uids)

    rows =
      Enum.map(uids, fn uid ->
        resolutions = resolve_inputs(inputs, uid, availability, metadata, now)
        values = Map.new(resolutions, fn {key, resolution} -> {key, resolution.value} end)
        {verdict, status, matched_rule_id} = decide(check, uid, values, rules)

        %{
          device_uid: uid,
          verdict: verdict,
          status: status,
          matched_rule_id: matched_rule_id,
          inputs: snapshot(resolutions)
        }
      end)

    {:ok, rows}
  end

  defp decide(check, uid, values, rules) do
    case Evaluator.verdict(values, rules) do
      {:ok, decision} ->
        {decision.verdict, decision.status, decision.matched_rule_id}

      {:error, :no_matching_rule} ->
        Logger.warning("composite check has no matching rule and no catch-all",
          check_id: check.id,
          device_uid: uid
        )

        {"inconclusive", :unknown, nil}
    end
  end

  defp resolve_inputs(inputs, uid, availability, metadata, now) do
    Map.new(inputs, fn input ->
      resolution =
        case input.kind do
          :vantage_point ->
            agent_id = Map.get(input.config, "agent_id")
            row = availability |> Map.get(uid, %{}) |> Map.get(agent_id)
            Resolvers.VantagePoint.resolve(input, row, now)

          :device_metadata ->
            Resolvers.DeviceMetadata.resolve(input, Map.get(metadata, uid, %{}), now)
        end

      {input.key, resolution}
    end)
  end

  defp snapshot(resolutions) do
    Map.new(resolutions, fn {key, resolution} ->
      {key,
       %{
         "value" => to_string(resolution.value),
         "observed_at" => resolution.observed_at && DateTime.to_iso8601(resolution.observed_at),
         "stale" => resolution.stale,
         "reason" => resolution.reason && to_string(resolution.reason)
       }}
    end)
  end

  defp load_availability(inputs, uids) do
    agent_ids =
      inputs
      |> Enum.filter(&(&1.kind == :vantage_point))
      |> Enum.map(&Map.get(&1.config, "agent_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if agent_ids == [] do
      %{}
    else
      DeviceAgentAvailability
      |> where([r], r.device_uid in ^uids and r.agent_id in ^agent_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.device_uid)
      |> Map.new(fn {uid, rows} -> {uid, Map.new(rows, &{&1.agent_id, &1})} end)
    end
  end

  defp load_metadata(inputs, uids) do
    if Enum.any?(inputs, &(&1.kind == :device_metadata)) do
      Device
      |> where([d], d.uid in ^uids)
      |> select([d], {d.uid, d.metadata})
      |> Repo.all()
      |> Map.new()
    else
      %{}
    end
  end

  defp persist_canonical_availability(%{write_canonical_availability: true}, rows, actor) do
    Enum.each(rows, fn row ->
      case canonical_available(row.status) do
        nil ->
          :ok

        available? ->
          write_device_availability(row.device_uid, available?, actor)
      end
    end)
  end

  defp persist_canonical_availability(_check, _rows, _actor), do: :ok

  defp canonical_available(:healthy), do: true
  defp canonical_available(:down), do: false
  defp canonical_available(_status), do: nil

  defp write_device_availability(device_uid, available?, actor) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, device} ->
        device = unwrap_device(device)

        case device
             |> Ash.Changeset.for_update(:set_availability, %{is_available: available?},
               actor: actor
             )
             |> Ash.update() do
          {:ok, _device} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "composite check failed to write canonical availability",
              device_uid: device_uid,
              reason: inspect(reason)
            )
        end

      _missing ->
        :ok
    end
  end

  defp unwrap_device(%{results: [device | _]}), do: device
  defp unwrap_device([device | _]), do: device
  defp unwrap_device(device), do: device

  defp persist_page(check, rows, started_at, actor) do
    existing = load_existing(check, rows)

    Enum.flat_map(rows, fn row ->
      prior = Map.get(existing, row.device_uid)
      changed? = is_nil(prior) or prior.verdict != row.verdict
      changed_at = if changed?, do: started_at, else: prior.changed_at

      upsert!(check, row, started_at, changed_at, actor)

      if changed?, do: [transition(check, row, prior)], else: []
    end)
  end

  defp load_existing(_check, []), do: %{}

  defp load_existing(check, rows) do
    uids = Enum.map(rows, & &1.device_uid)

    DeviceCompositeCheckResult
    |> where([r], r.check_id == ^check.id and r.device_uid in ^uids)
    |> Repo.all()
    |> Map.new(&{&1.device_uid, &1})
  end

  defp upsert!(check, row, evaluated_at, changed_at, actor) do
    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: row.device_uid,
        check_id: check.id,
        verdict: row.verdict,
        status: row.status,
        matched_rule_id: row.matched_rule_id,
        inputs: row.inputs,
        evaluated_at: evaluated_at,
        changed_at: changed_at
      },
      actor: actor,
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  defp transition(check, row, prior) do
    %{
      device_uid: row.device_uid,
      check_id: check.id,
      from_verdict: prior && prior.verdict,
      to_verdict: row.verdict,
      from_status: prior && prior.status,
      to_status: row.status,
      inputs: row.inputs
    }
  end

  defp sweep_out_of_scope(check, started_at) do
    {count, _} =
      DeviceCompositeCheckResult
      |> where([r], r.check_id == ^check.id and r.evaluated_at < ^started_at)
      |> Repo.delete_all()

    count
  end
end
