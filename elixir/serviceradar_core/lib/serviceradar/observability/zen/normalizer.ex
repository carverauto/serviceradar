defmodule ServiceRadar.Observability.Zen.Normalizer do
  @moduledoc """
  In-process Zen rule normalization for core EventWriter ingestion.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.Zen.Native
  alias ServiceRadar.Observability.ZenRule

  require Ash.Query
  require Logger

  @rule_groups %{
    "logs.syslog" => [
      "passthrough",
      "coraza_waf",
      "strip_full_message",
      "syslog_severity",
      "cef_severity"
    ],
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
    subject = normalized_subject(subject)

    case cached_runtime_rules(subject) do
      {:ok, rules} ->
        {:ok, rules}

      {:error, reason} ->
        Logger.warning("Zen DB rule lookup failed; falling back to bundled rules",
          subject: subject,
          reason: inspect(reason)
        )

        bundled_rules_for_subject(subject)
    end
  end

  def rules_for_subject(_subject), do: {:ok, []}

  @doc false
  @spec invalidate_subject(String.t() | nil) :: :ok
  def invalidate_subject(subject) when is_binary(subject) do
    :persistent_term.erase({__MODULE__, :runtime_rules, normalized_subject(subject)})
    :ok
  end

  def invalidate_subject(_subject), do: :ok

  @doc false
  @spec invalidate_rule(%{optional(atom()) => term()}) :: :ok
  def invalidate_rule(%{subject: subject}), do: invalidate_subject(subject)
  def invalidate_rule(_rule), do: :ok

  @doc false
  @spec invalidate_all() :: :ok
  def invalidate_all do
    key = {__MODULE__, :runtime_rules_known_subjects}

    key
    |> :persistent_term.get([])
    |> Enum.each(fn subject ->
      :persistent_term.erase({__MODULE__, :runtime_rules, subject})
    end)

    :persistent_term.erase(key)
    :ok
  end

  defp bundled_rules_for_subject(subject) do
    rule_names = Map.get(@rule_groups, subject, [])

    rule_names
    |> Enum.map(&load_rule/1)
    |> collect_rules()
  end

  defp normalized_subject(subject) do
    subject
    |> String.trim()
    |> String.replace_suffix(".processed", "")
  end

  defp cached_runtime_rules(subject) do
    key = {__MODULE__, :runtime_rules, subject}

    case :persistent_term.get(key, :missing) do
      :missing ->
        with {:ok, rules} <- load_runtime_rules(subject) do
          :persistent_term.put(key, {:ok, rules})
          remember_subject(subject)
          {:ok, rules}
        end

      cached ->
        cached
    end
  end

  defp load_runtime_rules(subject) do
    case runtime_rule_loader() do
      nil -> load_runtime_rules_from_db(subject)
      loader -> loader.load_rules(subject)
    end
  end

  defp load_runtime_rules_from_db(subject) do
    if repo_enabled?() do
      ZenRule
      |> Ash.Query.for_read(:active, %{})
      |> Ash.Query.filter(expr(subject == ^subject and stream_name == "events"))
      |> Ash.Query.sort(order: :asc, inserted_at: :asc)
      |> Ash.read(actor: SystemActor.system(:zen_normalizer))
      |> case do
        {:ok, rules} -> encode_runtime_rules(rules)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :repo_unavailable}
    end
  end

  defp encode_runtime_rules(rules) do
    rules
    |> Enum.map(fn %ZenRule{name: name, compiled_jdm: compiled_jdm} ->
      with {:ok, encoded} <- Jason.encode(compiled_jdm) do
        {:ok, {name, encoded}}
      end
    end)
    |> collect_rules()
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end

  defp runtime_rule_loader do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:runtime_rule_loader)
  end

  defp remember_subject(subject) do
    key = {__MODULE__, :runtime_rules_known_subjects}

    known =
      key
      |> :persistent_term.get([])
      |> Enum.uniq()

    :persistent_term.put(key, Enum.uniq([subject | known]))
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
