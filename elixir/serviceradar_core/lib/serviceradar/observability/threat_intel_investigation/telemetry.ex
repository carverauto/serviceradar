defmodule ServiceRadar.Observability.ThreatIntelInvestigation.Telemetry do
  @moduledoc """
  Query telemetry for threat-intel investigation reads.

  `span/3` emits `[:serviceradar, :threat_intel, :investigation, :query]`
  as `:start`, `:stop`, and `:exception`. Stop metadata carries `entity`, the
  names of the filters in use, `result_count` on success, and on failure
  `error: :timeout | :invalid_input | :query_failed`. Filter values (addresses,
  indicators, sources), cursors, and raw error terms are not part of that
  stop metadata. A raised exception is reported on `:exception` with the runtime
  reason, which is how `:telemetry.span/3` records a failure that is not returned
  as `{:error, _}`.
  """

  @event [:serviceradar, :threat_intel, :investigation, :query]
  @input_errors [:invalid_ip, :invalid_cidr, :invalid_severity, :invalid_run_id, :invalid_cursor]
  @unreported_options [:limit, :cursor]

  @spec event() :: [atom()]
  def event, do: @event

  @spec span(atom(), keyword(), (-> result)) :: result when result: term()
  def span(entity, opts, fun) when is_atom(entity) and is_list(opts) and is_function(fun, 0) do
    metadata = %{entity: entity, filters: filter_names(opts)}

    :telemetry.span(@event, metadata, fn ->
      result = fun.()
      {result, Map.merge(metadata, outcome(result))}
    end)
  end

  defp filter_names(opts) do
    opts
    |> Enum.reject(fn {key, value} -> key in @unreported_options or value in [nil, "", false] end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp outcome({:ok, %{rows: rows}}) when is_list(rows),
    do: %{result: :ok, result_count: length(rows)}

  defp outcome({:ok, rows}) when is_list(rows), do: %{result: :ok, result_count: length(rows)}
  defp outcome({:ok, %{} = map}), do: %{result: :ok, result_count: map_size(map)}
  defp outcome({:error, reason}), do: %{result: :error, error: error_kind(reason)}
  defp outcome(_other), do: %{result: :ok}

  defp error_kind(reason) when reason in @input_errors, do: :invalid_input
  defp error_kind(%{postgres: %{code: :query_canceled}}), do: :timeout

  defp error_kind(%DBConnection.ConnectionError{reason: reason})
       when reason in [:timeout, :queue_timeout], do: :timeout

  defp error_kind(%{errors: [first | _]}), do: error_kind(first)
  defp error_kind(%{error: error}) when not is_nil(error), do: error_kind(error)
  defp error_kind(_reason), do: :query_failed
end
