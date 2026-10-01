defmodule ServiceRadarWebNG.Plugins.PluginFleet do
  @moduledoc """
  Safe WASM assignment and current runtime evidence, keyed by partition and agent.
  Success/failure timestamps describe the latest result, not a history scan.
  Neither assignment parameters nor raw result messages/payloads are returned.
  """

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  def rows(scope) do
    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([
        :agent_uid,
        :partition_id,
        :plugin_id,
        :plugin_package_id,
        :enabled,
        :source,
        :policy_id,
        :interval_seconds,
        :timeout_seconds,
        :updated_at
      ])
      |> Ash.read!(scope: scope)

    packages =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([:plugin_id, :name, :version, :status, :content_hash, :runtime, :outputs])
      |> Ash.read!(scope: scope)

    states =
      ServiceState
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(service_type == "plugin")
      |> Ash.read!(scope: scope)

    build_rows(assignments, packages, states, DateTime.utc_now())
  end

  @doc false
  def build_rows(assignments, packages, states, now) do
    packages_by_id = Map.new(packages, &{&1.id, &1})
    states_by_agent = Enum.group_by(states, &{&1.partition, &1.agent_id})

    assignments =
      assignments
      |> Enum.reject(&is_nil(&1.partition_id))
      |> Enum.group_by(&{&1.partition_id, &1.agent_uid, &1.plugin_id})
      |> Enum.map(fn {_key, group} ->
        Enum.max_by(group, &{&1.enabled, DateTime.to_unix(&1.updated_at, :microsecond), &1.id})
      end)

    names =
      packages
      |> Enum.group_by(& &1.name)
      |> Map.new(fn {name, group} -> {name, MapSet.new(group, & &1.plugin_id)} end)

    assigned =
      Enum.map(assignments, fn assignment ->
        package = Map.get(packages_by_id, assignment.plugin_package_id)

        state =
          states_by_agent
          |> Map.get({assignment.partition_id, assignment.agent_uid}, [])
          |> Enum.filter(&matches_package?(&1, package, names))
          |> winner()

        row(assignment, package, state, now)
      end)

    keys = MapSet.new(assignments, &{&1.partition_id, &1.agent_uid, &1.plugin_id})

    observed_only =
      states
      |> Enum.filter(fn state ->
        id = PluginStateContract.state_plugin_id(state)
        is_binary(id) and not MapSet.member?(keys, {state.partition, state.agent_id, id})
      end)
      |> Enum.group_by(&{&1.partition, &1.agent_id, PluginStateContract.state_plugin_id(&1)})
      |> Enum.map(fn {_key, group} -> row(nil, nil, winner(group), now) end)

    assigned ++ observed_only
  end

  defp matches_package?(_state, nil, _names), do: false

  defp matches_package?(state, package, names) do
    # Legacy name-only evidence is usable only for an unambiguous plugin name.
    explicit_id? = is_binary(PluginStateContract.state_plugin_id(state))
    unique_name? = MapSet.size(Map.get(names, package.name, MapSet.new())) == 1

    (explicit_id? or unique_name?) and
      PluginStateContract.package_matches_state?(state, package.name, package.plugin_id)
  end

  defp winner([]), do: nil
  defp winner(states), do: Enum.max_by(states, &PluginStateContract.state_rank/1)

  defp row(assignment, package, state, now) do
    placeholder? = not is_nil(state) and PluginStateContract.placeholder_state?(state)
    reported_at = if state && not placeholder?, do: observed_at(state)
    age = if reported_at, do: max(DateTime.diff(now, reported_at, :second), 0)
    interval = if assignment, do: assignment.interval_seconds, else: 60
    stale? = not is_nil(age) and age > max(180, interval * 3)
    details = decode_details(state)
    result_status = if reported_at, do: reported_status(details)
    observed_version = if not placeholder?, do: reported_version(details)
    assigned_version = if package, do: package.version
    available = if reported_at, do: state.available
    {category, reason} = classify(assignment, package, state, reported_at, stale?)
    drift = known_drift(assigned_version, observed_version)
    observed_assignment_id = if reported_at, do: reported_assignment_id(details)
    assignment_drift = known_drift(if(assignment, do: assignment.id), observed_assignment_id)

    {category, reason} =
      cond do
        category == "healthy" and (drift == true or assignment_drift == true) ->
          {"action_required", "desired_state_not_converged"}

        category == "healthy" and result_status in ["WARNING", "CRITICAL", "UNKNOWN"] ->
          {"action_required", "runtime_reported_non_ok"}

        true ->
          {category, reason}
      end

    %{
      "partition_id" => if(assignment, do: assignment.partition_id, else: state.partition),
      "agent_uid" => if(assignment, do: assignment.agent_uid, else: state.agent_id),
      "plugin_id" => if(assignment, do: assignment.plugin_id, else: PluginStateContract.state_plugin_id(state)),
      "plugin_name" => if(package, do: package.name),
      "assignment_id" => if(assignment, do: assignment.id),
      "observed_assignment_id" => observed_assignment_id,
      "assignment_drift" => assignment_drift,
      "assigned" => not is_nil(assignment),
      "enabled" => not is_nil(assignment) and assignment.enabled,
      "source" => if(assignment, do: to_string(assignment.source)),
      "policy_id" => if(assignment, do: assignment.policy_id),
      "interval_seconds" => if(assignment, do: assignment.interval_seconds),
      "timeout_seconds" => if(assignment, do: assignment.timeout_seconds),
      "package_id" => if(package, do: package.id),
      "package_status" => if(package, do: to_string(package.status)),
      "content_hash" => if(package, do: package.content_hash),
      "runtime" => if(package, do: package.runtime),
      "outputs" => if(package, do: package.outputs),
      "assigned_version" => assigned_version,
      "observed_version" => observed_version,
      "version_drift" => drift,
      "observed_state" => runtime_state(state, placeholder?),
      "available" => available,
      "result_status" => result_status,
      "reported_at" => reported_at,
      "evidence_age_seconds" => age,
      "stale" => stale?,
      "last_success_at" => if(available == true, do: reported_at),
      "last_failure_at" => if(available == false, do: reported_at),
      "last_error" => if(available == false, do: "plugin_result_unavailable"),
      "category" => category,
      "reason_code" => reason
    }
  end

  defp classify(nil, _package, _state, _reported_at, true), do: {"observed_only", "observed_only_stale"}
  defp classify(nil, _package, _state, _reported_at, false), do: {"observed_only", "no_managed_assignment"}

  defp classify(%{enabled: false}, _package, _state, _reported_at, _stale),
    do: {"expected_inactive", "assignment_disabled"}

  defp classify(_assignment, nil, _state, _reported_at, _stale), do: {"action_required", "desired_package_missing"}

  defp classify(_assignment, %{status: status}, _state, _reported_at, _stale) when status != :approved,
    do: {"action_required", "desired_package_not_approved"}

  defp classify(_assignment, _package, _state, nil, _stale), do: {"unavailable", "runtime_not_reported"}
  defp classify(_assignment, _package, _state, _reported_at, true), do: {"unavailable", "runtime_observation_stale"}
  defp classify(_assignment, _package, %{state: "inactive"}, _reported_at, false), do: {"unavailable", "runtime_inactive"}

  defp classify(_assignment, _package, %{available: false}, _reported_at, false),
    do: {"action_required", "runtime_reported_unhealthy"}

  defp classify(_assignment, _package, _state, _reported_at, false), do: {"healthy", "latest_result_available"}

  defp runtime_state(nil, _placeholder), do: "not_reported"
  defp runtime_state(%{message: "streaming plugin ready"}, true), do: "ready"
  defp runtime_state(_state, true), do: "pending"
  defp runtime_state(%{state: "inactive"}, false), do: "inactive"
  defp runtime_state(%{available: true}, false), do: "available"
  defp runtime_state(_state, false), do: "unavailable"

  defp observed_at(state) do
    PluginStateContract.details_logical_observed_at(state.details, state.last_observed_at)
  end

  defp decode_details(nil), do: %{}

  defp decode_details(%{details: details}) do
    case Jason.decode(details || "{}") do
      {:ok, value} when is_map(value) ->
        result = Map.get(value, "reported_result")
        result = if is_map(result), do: result, else: %{}
        labels = Map.get(value, "labels") || Map.get(result, "labels")

        %{
          "labels" => if(is_map(labels), do: labels, else: %{}),
          "package_version" => Map.get(value, "package_version") || Map.get(result, "package_version"),
          "status" => Map.get(value, "status") || Map.get(result, "status")
        }

      _ ->
        %{}
    end
  end

  defp reported_version(details) do
    # There is no version in the host-authored result envelope today. Only use
    # an explicitly reported package version; never infer it from desired state.
    value = get_in(details, ["labels", "package_version"]) || Map.get(details, "package_version")
    if is_binary(value) and byte_size(value) <= 64 and Regex.match?(~r/\A[0-9A-Za-z.+_-]+\z/, value), do: value
  end

  defp reported_assignment_id(details) do
    case Ecto.UUID.cast(get_in(details, ["labels", "assignment_id"])) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp reported_status(%{"status" => status}) when is_binary(status) do
    normalized = String.upcase(status)
    if normalized in ["OK", "WARNING", "CRITICAL", "UNKNOWN"], do: normalized
  end

  defp reported_status(_details), do: nil

  defp known_drift(left, right) when is_binary(left) and is_binary(right), do: left != right
  defp known_drift(_left, _right), do: nil
end
