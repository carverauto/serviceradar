defmodule ServiceRadarWebNG.SRQL.FleetQuery do
  @moduledoc "Executes compiler-validated fleet plans using scoped Ash read models."

  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.Plugins.PluginFleet
  alias ServiceRadarWebNG.SRQL.EntityAccess

  @native_fields ~w(agent_uid agent_label addon_id addon_name package_id assigned_version
    latest_approved_version content_hash package_status verification_status degradation_reason
    reported_at last_health_at last_scan_at category reason_code evidence_age_seconds rollout_state update_policy)
  @time_fields ~w(reported_at last_health_at last_scan_at last_success_at last_failure_at)

  def execute(%{"entity" => entity} = plan, scope) do
    with :ok <- EntityAccess.authorize("in:#{entity}", scope) do
      rows = entity |> rows(scope) |> apply_plan(plan)
      fields = Map.fetch!(plan, "fields")
      {:ok, %Postgrex.Result{columns: fields, rows: Enum.map(rows, fn row -> Enum.map(fields, &Map.get(row, &1)) end)}}
    end
  rescue
    _error in Ash.Error.Forbidden -> {:error, :forbidden}
    error in Ash.Error.Invalid -> {:error, error}
  end

  defp rows("addon_fleet", scope) do
    [scope: scope, max_rows: nil]
    |> AddonFleet.rows()
    |> Enum.map(&native_row/1)
  end

  defp rows("plugin_fleet", scope), do: PluginFleet.rows(scope)

  defp native_row(row) do
    projected =
      Map.new(@native_fields, fn field ->
        value = Map.get(row, String.to_existing_atom(field))
        value = if is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value), else: value
        {field, value}
      end)
    age = row.evidence_age_seconds
    threshold = Application.get_env(:serviceradar_web_ng, :addon_status_freshness_seconds, 180)

    Map.merge(projected, %{
      "assigned" => row.assigned?,
      "enabled" => row.enabled?,
      "active" => row.active?,
      "observed_state" => row.running_state,
      "observed_version" => row.running_version,
      "stale" => not is_nil(age) and age > threshold,
      "version_drift" => native_version_drift(row)
    })
  end

  defp native_version_drift(%{assigned_version: left, running_version: right}) when is_binary(left) and is_binary(right),
    do: left != right

  defp native_version_drift(_row), do: nil

  @doc false
  def apply_plan(rows, plan) do
    rows
    |> Enum.filter(fn row ->
      in_time_range?(row, plan["time_range"]) and
        Enum.all?(plan["filters"], &matches?(row, &1))
    end)
    |> Enum.sort(fn left, right -> compare_rows(left, right, plan["order"]) != :gt end)
    |> Enum.drop(plan["offset"])
    |> Enum.take(plan["limit"])
  end

  defp in_time_range?(_row, nil), do: true

  defp in_time_range?(row, %{"start" => start_at, "end" => end_at}) do
    observed = comparable(row["reported_at"])
    not is_nil(observed) and observed >= timestamp_value(start_at) and observed <= timestamp_value(end_at)
  end

  defp matches?(row, %{"field" => field, "op" => op, "value" => value}) do
    actual = comparable(row[field])
    expected = if field in @time_fields, do: timestamp_value(value), else: comparable(value)

    if is_nil(actual) do
      false
    else
      match_value?(actual, op, expected)
    end
  end

  defp match_value?(actual, "eq", expected), do: actual == expected
  defp match_value?(actual, "not_eq", expected), do: actual != expected
  defp match_value?(actual, "in", expected), do: actual in expected
  defp match_value?(actual, "not_in", expected), do: actual not in expected
  defp match_value?(actual, "gt", expected), do: actual > expected
  defp match_value?(actual, "gte", expected), do: actual >= expected
  defp match_value?(actual, "lt", expected), do: actual < expected
  defp match_value?(actual, "lte", expected), do: actual <= expected
  defp match_value?(actual, "like", expected), do: like?(actual, expected)
  defp match_value?(actual, "not_like", expected), do: not like?(actual, expected)

  defp like?(actual, pattern) do
    regex = pattern |> Regex.escape() |> String.replace("%", ".*") |> String.replace("_", ".")
    Regex.match?(Regex.compile!("\\A" <> regex <> "\\z", "isu"), actual)
  end

  defp compare_rows(_left, _right, []), do: :eq

  defp compare_rows(left, right, [%{"field" => field, "direction" => direction} | rest]) do
    case compare(comparable(left[field]), comparable(right[field]), direction) do
      :eq -> compare_rows(left, right, rest)
      ordering -> ordering
    end
  end

  defp compare(value, value, _direction), do: :eq
  defp compare(nil, _right, _direction), do: :gt
  defp compare(_left, nil, _direction), do: :lt
  defp compare(left, right, "asc") when left < right, do: :lt
  defp compare(left, right, "desc") when left > right, do: :lt
  defp compare(_left, _right, _direction), do: :gt

  defp timestamp_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :microsecond)
      _ -> value
    end
  end

  defp timestamp_value(value) when is_list(value), do: Enum.map(value, &timestamp_value/1)
  defp comparable(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp comparable(value) when is_list(value), do: Enum.map(value, &comparable/1)
  defp comparable(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp comparable(value), do: value
end
