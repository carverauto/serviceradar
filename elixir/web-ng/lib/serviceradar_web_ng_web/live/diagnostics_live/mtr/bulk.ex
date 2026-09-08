defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Bulk do
  @moduledoc false

  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params

  def normalize_protocol(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()
    if value in Config.protocols(), do: value, else: Config.protocol_icmp()
  end

  def normalize_execution_profile(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()
    if value in Config.execution_profiles(), do: value, else: Config.execution_profile_fast()
  end

  def normalize_form_params(params) when is_map(params) do
    %{
      "targets" => to_string(Map.get(params, Config.payload_targets_key(), "")),
      Config.payload_target_query_key() => to_string(Map.get(params, Config.payload_target_query_key(), "")),
      Config.payload_selector_limit_key() => to_string(Map.get(params, Config.payload_selector_limit_key(), "100")),
      "agent_id" => to_string(Map.get(params, Config.payload_agent_id_key(), "")),
      Config.payload_protocol_key() =>
        normalize_protocol(Map.get(params, Config.payload_protocol_key(), Config.protocol_icmp())),
      Config.payload_execution_profile_key() =>
        normalize_execution_profile(
          Map.get(params, Config.payload_execution_profile_key(), Config.execution_profile_fast())
        ),
      "concurrency" => to_string(Map.get(params, Config.payload_concurrency_key(), "64"))
    }
  end

  def targets_from_params(params, selector_limit) when is_map(params) and is_integer(selector_limit) do
    query = params |> Map.get(Config.payload_target_query_key(), "") |> to_string() |> String.trim()

    case query do
      "" -> params |> manual_targets() |> wrap_manual_targets()
      _ -> query |> MtrAutomationDispatcher.target_contexts_from_srql(selector_limit) |> wrap_srql_targets()
    end
  end

  def target_query(params) when is_map(params) do
    params |> Map.get(Config.payload_target_query_key(), "") |> Params.normalize_text()
  end

  def validate_agent(""), do: {:error, :missing_agent}
  def validate_agent(nil), do: {:error, :missing_agent}
  def validate_agent(_agent_id), do: :ok

  def parse_positive_integer(nil, default), do: default

  def parse_positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  def count(job, key, default) do
    payload = job.result_payload || job.progress_payload || %{}
    Map.get(payload, key, default)
  end

  def count_targets(job) do
    job |> Map.get(:payload, %{}) |> Map.get("targets", []) |> List.wrap() |> length()
  end

  def rate(job) do
    payload = job.result_payload || job.progress_payload || %{}

    case Map.get(payload, Config.payload_targets_per_minute_key()) do
      value when is_float(value) -> "#{Float.round(value, 1)} targets/min"
      value when is_integer(value) -> "#{value}.0 targets/min"
      value when is_binary(value) -> "#{value} targets/min"
      _ -> "-"
    end
  end

  def rate_value(job) do
    payload = job.result_payload || job.progress_payload || %{}
    extract_float_metric(payload, Config.payload_targets_per_minute_key()) || 0.0
  end

  def duration(job) do
    payload = job.result_payload || job.progress_payload || %{}

    case Map.get(payload, Config.payload_duration_ms_key()) do
      value when is_integer(value) and value > 0 -> "#{div(value, 1000)}s"
      value when is_binary(value) -> parse_duration(value)
      _ -> "-"
    end
  end

  def concurrency(job) do
    payload = job.result_payload || job.progress_payload || %{}
    current = Map.get(payload, Config.payload_concurrency_key())
    max = Map.get(payload, Config.payload_max_concurrency_key())

    case {current, max} do
      {curr, maxc} when is_integer(curr) and is_integer(maxc) and maxc > 0 and curr != maxc -> "#{curr}/#{maxc}"
      {curr, maxc} when is_integer(curr) and is_integer(maxc) and maxc > 0 -> "#{curr}"
      {curr, _} when is_integer(curr) -> "#{curr}"
      _ -> "-"
    end
  end

  def timeout_count(job), do: count(job, Config.payload_timed_out_targets_key(), 0)

  def success_rate(job) do
    total_targets = count(job, Config.payload_total_targets_key(), count_targets(job))
    completed_targets = count(job, Config.payload_completed_targets_key(), 0)
    Float.round(safe_ratio(completed_targets, total_targets) * 100, 1)
  end

  def mix(job) do
    total_targets = count(job, Config.payload_total_targets_key(), count_targets(job))
    completed_targets = count(job, Config.payload_completed_targets_key(), 0)
    failed_targets = count(job, Config.payload_failed_targets_key(), 0)
    timed_out_targets = timeout_count(job)

    %{
      total_targets: total_targets,
      completed_targets: completed_targets,
      timed_out_targets: timed_out_targets,
      error_targets: max(failed_targets - timed_out_targets, 0)
    }
  end

  def concurrency_history(job) do
    payload = job.result_payload || job.progress_payload || %{}

    payload
    |> Map.get(Config.payload_concurrency_history_key(), [])
    |> List.wrap()
    |> Enum.map(&history_sample/1)
    |> Enum.reject(&is_nil/1)
  end

  def throttled?(job) do
    payload = job.result_payload || job.progress_payload || %{}
    history = concurrency_history(job)

    if history == [] do
      current = Map.get(payload, Config.payload_concurrency_key())
      max = Map.get(payload, Config.payload_max_concurrency_key())
      is_integer(current) and is_integer(max) and max > current
    else
      Enum.any?(history, &(&1.max_concurrency > 0 and &1.concurrency < &1.max_concurrency))
    end
  end

  def job_query(job),
    do: job |> Map.get(:payload, %{}) |> Map.get(Config.payload_target_query_key()) |> Params.normalize_text()

  def job_profile_id(job) do
    context = Map.get(job, :context, %{}) || %{}
    Params.normalize_text(Map.get(context, "mtr_policy_id") || Map.get(context, :mtr_policy_id))
  end

  def job_selector_limit(job), do: job |> Map.get(:payload, %{}) |> Map.get(Config.payload_selector_limit_key(), "-")

  def dashboard_stats(jobs) do
    jobs = List.wrap(jobs)
    completed = Enum.filter(jobs, &(&1.status == :completed))

    %{
      active_count: Enum.count(jobs, &(&1.status in [:queued, :sent, :acknowledged, :running])),
      throttled_count: Enum.count(jobs, &throttled?/1),
      avg_rate: Float.round(average_rate(completed), 1),
      avg_success_rate: Float.round(average_success_rate(completed), 1),
      timed_out_targets: completed |> Enum.map(&timeout_count/1) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      total_targets:
        completed
        |> Enum.map(&count(&1, Config.payload_total_targets_key(), count_targets(&1)))
        |> Enum.filter(&is_integer/1)
        |> Enum.sum()
    }
  end

  def recent_job_bars(jobs) do
    jobs = List.wrap(jobs)
    completed_jobs = Enum.filter(jobs, &(&1.status == :completed and rate_value(&1) > 0))
    if completed_jobs == [], do: Enum.take(jobs, 8), else: Enum.take(completed_jobs, 8)
  end

  def bar_width(job, max_rate), do: "#{Float.round(safe_ratio(rate_value(job), max_rate) * 100, 1)}%"

  def history_bar_width(sample) do
    ratio = safe_ratio(Map.get(sample, :concurrency, 0), Map.get(sample, :max_concurrency, 0))
    "#{Float.round(ratio * 100, 1)}%"
  end

  def latest_history(jobs) do
    Enum.find_value(List.wrap(jobs), fn job ->
      history = concurrency_history(job)
      if history == [], do: nil, else: %{job: job, history: history}
    end)
  end

  def latest_mix(jobs) do
    Enum.find_value(List.wrap(jobs), fn job ->
      mix = mix(job)
      if mix.total_targets > 0, do: %{job: job, mix: mix}
    end)
  end

  def mix_segment_width(count, total), do: "#{Float.round(safe_ratio(count, total) * 100, 1)}%"

  defp manual_targets(params) do
    params
    |> Map.get("targets", "")
    |> to_string()
    |> String.split(~r/[\r\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp target_from_ctx(target_ctx) when is_map(target_ctx) do
    target =
      Map.get(target_ctx, :target) ||
        Map.get(target_ctx, "target") ||
        Map.get(target_ctx, :target_ip) ||
        Map.get(target_ctx, "target_ip")

    Params.normalize_text(target)
  end

  defp target_from_ctx(_), do: nil

  defp wrap_manual_targets([]), do: {:error, :missing_targets}
  defp wrap_manual_targets(targets), do: {:ok, targets}
  defp wrap_srql_targets({:ok, []}), do: {:error, :empty_srql_targets}
  defp wrap_srql_targets({:error, reason}), do: {:error, {:srql_query_failed, reason}}

  defp wrap_srql_targets({:ok, target_contexts}),
    do:
      target_contexts
      |> Enum.map(&target_from_ctx/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> wrap_srql_resolved_targets()

  defp wrap_srql_resolved_targets([]), do: {:error, :empty_srql_targets}
  defp wrap_srql_resolved_targets(targets), do: {:ok, targets}

  defp history_sample(%{} = sample) do
    %{
      elapsed_ms: extract_int_metric(sample, Config.payload_elapsed_ms_key()) || 0,
      concurrency: extract_int_metric(sample, Config.payload_concurrency_key()) || 0,
      max_concurrency: extract_int_metric(sample, Config.payload_max_concurrency_key()) || 0
    }
  end

  defp history_sample(_), do: nil

  defp parse_duration(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> "#{div(parsed, 1000)}s"
      _ -> "-"
    end
  end

  defp average_rate(jobs), do: jobs |> Enum.map(&rate_value/1) |> Enum.reject(&(&1 <= 0)) |> average_float()
  defp average_success_rate(jobs), do: jobs |> Enum.map(&success_rate/1) |> average_float()
  defp average_float([]), do: 0.0
  defp average_float(values), do: Enum.sum(values) / length(values)
  defp safe_ratio(_value, max_value) when max_value in [0, 0.0], do: 0.0
  defp safe_ratio(value, max_value), do: min(1.0, max(value / max_value, 0.0))

  defp extract_float_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      value when is_binary(value) -> value |> Float.parse() |> parsed_float()
      _ -> nil
    end
  end

  defp extract_float_metric(_payload, _key), do: nil
  defp parsed_float({parsed, ""}), do: parsed
  defp parsed_float(_), do: nil

  defp extract_int_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> value |> Integer.parse() |> parsed_int()
      _ -> nil
    end
  end

  defp parsed_int({parsed, ""}), do: parsed
  defp parsed_int(_), do: nil
end
