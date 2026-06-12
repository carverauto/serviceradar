defmodule ServiceRadar.Observability.Zen.Normalizer do
  @moduledoc """
  In-process Zen rule normalization for core EventWriter ingestion.
  """

  alias ServiceRadar.Observability.Zen.Native

  require Logger

  @rule_groups %{
    "logs.syslog" => ["passthrough", "coraza_waf", "strip_full_message", "cef_severity"],
    "logs.snmp" => ["passthrough", "snmp_severity"],
    "logs.otel" => ["passthrough"],
    "logs.internal.health" => ["passthrough"],
    "logs.internal.jobs" => ["passthrough"],
    "logs.internal.onboarding" => ["passthrough"],
    "logs.internal.audit" => ["passthrough"],
    "logs.internal.sweep" => ["passthrough"],
    "otel.metrics.raw" => ["passthrough"],
    "flows.raw.netflow" => ["netflow_to_ocsf"]
  }

  @doc """
  Applies the default Zen rules for a subject to a decoded JSON payload.
  """
  @spec normalize_json(String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def normalize_json(subject, payload) when is_map(payload) do
    with {:ok, rules} <- rules_for_subject(subject),
         {:ok, context_json} <- Jason.encode(payload),
         {:ok, normalized_json} <- Native.evaluate_rules(context_json, rules),
         {:ok, normalized} <- Jason.decode(normalized_json) do
      {:ok, normalized}
    else
      {:error, reason} = error ->
        Logger.warning("Zen normalization failed",
          subject: subject,
          reason: inspect(reason)
        )

        error
    end
  end

  def normalize_json(_subject, payload), do: {:ok, payload}

  @doc false
  @spec rules_for_subject(String.t() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def rules_for_subject(subject) when is_binary(subject) do
    rule_names = Map.get(@rule_groups, normalized_subject(subject), [])

    rule_names
    |> Enum.map(&load_rule/1)
    |> collect_rules()
  end

  def rules_for_subject(_subject), do: {:ok, []}

  defp normalized_subject(subject) do
    subject
    |> String.trim()
    |> String.replace_suffix(".processed", "")
  end

  defp load_rule(name) do
    case cached_rule(name) do
      {:ok, json} -> {:ok, {name, json}}
      error -> error
    end
  end

  defp cached_rule(name) do
    key = {__MODULE__, :rule, name}

    case :persistent_term.get(key, :missing) do
      :missing ->
        with {:ok, json} <- read_rule(name) do
          :persistent_term.put(key, json)
          {:ok, json}
        end

      json ->
        {:ok, json}
    end
  end

  defp read_rule(name) do
    name
    |> rule_path()
    |> File.read()
  end

  defp rule_path(name) do
    case :code.priv_dir(:serviceradar_core) do
      {:error, _} -> Path.expand("../../../../priv/zen/rules/#{name}.json", __DIR__)
      priv_dir -> Path.join([to_string(priv_dir), "zen", "rules", "#{name}.json"])
    end
  end

  defp collect_rules(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, rule}, {:ok, acc} -> {:cont, {:ok, [rule | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end
end
