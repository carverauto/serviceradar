defmodule ServiceRadar.Observability.ZenRuleSync do
  @moduledoc """
  GenServer that synchronizes Zen rules to the datasvc KV store.

  Reconciles rules on startup and at regular intervals.

  ## Usage

      # Sync a specific rule
      ZenRuleSync.sync_rule(rule)
  """

  use GenServer

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Observability.ZenRule

  require Ash.Query
  require Logger

  @reconcile_delay_ms 5_000
  @reconcile_interval_ms to_timeout(minute: 5)

  defstruct [:ash_opts]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the PID of the ZenRuleSync, or nil if not running.
  """
  @spec whereis() :: pid() | nil
  def whereis do
    GenServer.whereis(__MODULE__)
  end

  @doc """
  Syncs a rule to the KV store.
  """
  @spec sync_rule(ZenRule.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_rule(%ZenRule{} = rule, _opts \\ []) do
    if datasvc_available?() do
      # DB connection's search_path determines the schema
      opts = [actor: SystemActor.system(:zen_rule_sync)]
      sync_rule_impl(rule, opts)
    else
      {:error, :datasvc_unavailable}
    end
  end

  @doc """
  Deletes a rule from the KV store.
  """
  @spec delete_rule(ZenRule.t()) :: :ok | {:error, term()}
  def delete_rule(%ZenRule{} = rule) do
    if datasvc_available?() do
      case Client.delete(kv_key(rule)) do
        :ok ->
          _ = sync_subject_index(rule, actor: SystemActor.system(:zen_rule_sync))
          :ok

        error ->
          error
      end
    else
      {:error, :datasvc_unavailable}
    end
  end

  @doc """
  Returns the KV key for a rule.
  """
  @spec kv_key(ZenRule.t()) :: String.t()
  def kv_key(%ZenRule{} = rule) do
    "agents/#{rule.agent_id}/#{rule.stream_name}/#{rule.subject}/#{rule.name}.json"
  end

  @doc """
  Returns the KV key for the ordered rule index for a rule subject.
  """
  @spec kv_index_key(ZenRule.t()) :: String.t()
  def kv_index_key(%ZenRule{} = rule) do
    "agents/#{rule.agent_id}/#{rule.stream_name}/#{rule.subject}/_rules.json"
  end

  @doc """
  Triggers an immediate reconciliation.
  """
  @spec reconcile() :: :ok
  def reconcile do
    case whereis() do
      nil -> :ok
      pid -> GenServer.cast(pid, :reconcile)
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("ZenRuleSync starting")

    # Schedule first reconciliation
    Process.send_after(self(), :reconcile, @reconcile_delay_ms)

    # DB connection's search_path determines the schema
    {:ok,
     %__MODULE__{
       ash_opts: [actor: SystemActor.system(:zen_rule_sync)]
     }}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    do_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    do_reconcile(state)
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_reconcile(state) do
    if repo_enabled?() do
      if datasvc_available?() do
        reconcile_rules(state)
      else
        Logger.warning("Zen rule reconcile skipped: datasvc unavailable")
      end
    end
  end

  defp reconcile_rules(state) do
    query = Ash.Query.for_read(ZenRule, :active, %{})

    case Ash.read(query, state.ash_opts) do
      {:ok, rules} ->
        results = Enum.map(rules, &sync_rule_result(&1, state))

        results
        |> successful_rules()
        |> sync_rule_indexes()

        log_reconcile_results(results)

      {:error, reason} ->
        Logger.warning("Failed to load zen rules", reason: inspect(reason))
    end
  end

  defp sync_rule_result(rule, state) do
    case sync_rule_with_actor(rule, state) do
      {:ok, _} ->
        {:ok, rule}

      {:error, reason} ->
        {:error, reason, rule}

      unexpected ->
        {:error, {:unexpected_result, unexpected}, rule}
    end
  rescue
    error ->
      {:error, {:crash, Exception.message(error)}, rule}
  end

  @doc false
  @spec log_reconcile_results(list()) :: :ok
  def log_reconcile_results(results) do
    {success_count, transient_errors, actionable_errors} = categorize_results(results)

    Enum.each(actionable_errors, fn {reason, rule} ->
      formatted = format_reason(reason)

      Logger.warning(
        "Zen rule reconcile failed for rule #{rule.id} (#{rule.name}): #{formatted}",
        rule_id: rule.id,
        rule_name: rule.name,
        reason: formatted
      )
    end)

    total = length(results)
    transient_count = length(transient_errors)
    actionable_count = length(actionable_errors)

    cond do
      actionable_count > 0 ->
        Logger.warning(
          "Zen rule reconcile summary: total=#{total} success=#{success_count} failed=#{actionable_count} transient_failed=#{transient_count}"
        )

      transient_count > 0 ->
        reasons =
          transient_errors
          |> Enum.map(fn {reason, _rule} -> format_reason(reason) end)
          |> Enum.uniq()
          |> Enum.join(", ")

        Logger.warning(
          "Zen rule reconcile skipped due to transient datasvc error: count=#{transient_count} reason=#{reasons}"
        )

      true ->
        :ok
    end

    :ok
  end

  defp categorize_results(results) do
    Enum.reduce(results, {0, [], []}, &reduce_result/2)
  end

  defp reduce_result({:ok, _rule}, {success, transient, actionable}) do
    {success + 1, transient, actionable}
  end

  defp reduce_result({:error, reason, rule}, {success, transient, actionable}) do
    if transient_error?(reason) do
      {success, [{reason, rule} | transient], actionable}
    else
      {success, transient, [{reason, rule} | actionable]}
    end
  end

  defp transient_error?(reason) do
    case reason do
      :datasvc_unavailable ->
        true

      :not_connected ->
        true

      :not_started ->
        true

      :timeout ->
        true

      {:down, :normal} ->
        true

      {:down, _reason} ->
        true

      {:call_failed, _} ->
        true

      %GRPC.RPCError{status: status}
      when status in [:unavailable, :deadline_exceeded, :cancelled] ->
        true

      _ ->
        false
    end
  end

  defp format_reason(%GRPC.RPCError{} = error), do: GRPC.RPCError.message(error)
  defp format_reason({:json_encode_failed, message}), do: "json_encode_failed: #{message}"
  defp format_reason({:unexpected_result, result}), do: "unexpected_result: #{inspect(result)}"
  defp format_reason({:crash, message}), do: "crash: #{message}"
  defp format_reason(reason), do: inspect(reason)

  # Internal sync with opts from GenServer state
  defp sync_rule_with_actor(%ZenRule{} = rule, state) do
    sync_rule_impl(rule, state.ash_opts)
  end

  defp sync_rule_impl(%ZenRule{} = rule, opts) when is_list(opts) do
    if rule.enabled do
      key = kv_key(rule)

      with {:ok, payload} <- Jason.encode(rule.compiled_jdm),
           :ok <- Client.put(key, payload),
           {:ok, _value, revision} <- Client.get_with_revision(key),
           :ok <- update_kv_revision(rule, revision, opts),
           :ok <- sync_subject_index(rule, opts) do
        {:ok, revision}
      else
        {:error, %Jason.EncodeError{} = error} ->
          {:error, {:json_encode_failed, Exception.message(error)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case delete_rule(rule) do
        :ok -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp successful_rules(results) do
    Enum.flat_map(results, fn
      {:ok, rule} -> [rule]
      _ -> []
    end)
  end

  defp sync_rule_indexes(rules) do
    rules
    |> Enum.uniq_by(&{&1.agent_id, &1.stream_name, &1.subject})
    |> Enum.each(fn rule ->
      case sync_subject_index(rule, actor: SystemActor.system(:zen_rule_sync)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to sync zen rule index for #{rule.subject}: #{inspect(reason)}",
            subject: rule.subject,
            reason: inspect(reason)
          )
      end
    end)
  end

  defp sync_subject_index(%ZenRule{} = rule, opts) do
    with {:ok, rules} <- load_subject_rules(rule, opts),
         {:ok, payload} <- encode_subject_index(rule, rules) do
      Client.put(kv_index_key(rule), payload)
    else
      {:error, %Jason.EncodeError{} = error} ->
        {:error, {:json_encode_failed, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_subject_rules(%ZenRule{} = rule, opts) do
    ZenRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(
      expr(
        agent_id == ^rule.agent_id and
          stream_name == ^rule.stream_name and
          subject == ^rule.subject
      )
    )
    |> Ash.read(opts)
  end

  defp encode_subject_index(%ZenRule{} = rule, rules) do
    payload = %{
      version: 1,
      agent_id: rule.agent_id,
      stream_name: rule.stream_name,
      subject: rule.subject,
      rules:
        rules
        |> Enum.sort_by(&{&1.order || 0, &1.name})
        |> Enum.map(&%{key: &1.name, order: &1.order || 0})
    }

    Jason.encode(payload)
  end

  defp update_kv_revision(%ZenRule{} = rule, revision, opts) do
    rule
    |> Ash.Changeset.for_update(
      :set_kv_revision,
      %{kv_revision: revision},
      Keyword.put(opts, :context, %{skip_zen_sync: true})
    )
    |> Ash.update()
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end

  defp datasvc_available? do
    Application.get_env(:serviceradar_core, :datasvc_enabled, true) &&
      Client.connected?()
  end
end
