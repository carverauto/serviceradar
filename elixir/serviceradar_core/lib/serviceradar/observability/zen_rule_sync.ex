defmodule ServiceRadar.Observability.ZenRuleSync do
  @moduledoc """
  GenServer that synchronizes Zen rules to the datasvc KV store.

  Reconciles rules on startup and at regular intervals.

  ## Usage

      # Sync a specific rule
      ZenRuleSync.sync_rule(rule)
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Observability.ZenRule

  @reconcile_delay_ms 5_000
  @reconcile_interval_ms :timer.minutes(5)

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
      Client.delete(kv_key(rule))
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
    if repo_enabled?() && datasvc_available?() do
      reconcile_rules(state)
    end
  end

  defp reconcile_rules(state) do
    query = Ash.Query.for_read(ZenRule, :active, %{})

    case Ash.read(query, state.ash_opts) do
      {:ok, rules} ->
        Enum.each(rules, &sync_rule_with_logging(&1, state))

      {:error, reason} ->
        Logger.warning("Failed to load zen rules", reason: inspect(reason))
    end
  end

  defp sync_rule_with_logging(rule, state) do
    case sync_rule_with_actor(rule, state) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Zen rule reconcile failed",
          rule_id: rule.id,
          reason: inspect(reason)
        )

        :ok

      unexpected ->
        Logger.warning("Zen rule reconcile returned unexpected result",
          rule_id: rule.id,
          result: inspect(unexpected)
        )

        :ok
    end
  rescue
    error ->
      Logger.error("Zen rule reconcile crashed",
        rule_id: rule.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

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
           :ok <- update_kv_revision(rule, revision, opts) do
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
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end

  defp datasvc_available? do
    Application.get_env(:serviceradar_core, :datasvc_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.DataService.Client))
  end
end
