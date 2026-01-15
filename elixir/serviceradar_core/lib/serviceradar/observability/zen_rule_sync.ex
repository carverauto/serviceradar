defmodule ServiceRadar.Observability.ZenRuleSync do
  @moduledoc """
  Tenant-scoped GenServer that synchronizes Zen rules to the datasvc KV store.

  Each tenant has their own ZenRuleSync process that reconciles rules on startup
  and at regular intervals. This ensures tenant isolation - a tenant's process
  can only access and sync that tenant's rules.

  ## Starting

  ZenRuleSync is automatically started when:
  - A Zen rule is created for a tenant
  - Manually via `ensure_started/1`

  ## Usage

      # Ensure sync is running for a tenant
      ZenRuleSync.ensure_started(tenant_id)

      # Sync a specific rule
      ZenRuleSync.sync_rule(rule, tenant_id: tenant_id)
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Observability.ZenRule

  @reconcile_delay_ms 5_000
  @reconcile_interval_ms :timer.minutes(5)

  defstruct [:tenant_id, :tenant_schema, :ash_opts]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Ensures ZenRuleSync is running for a tenant, starting it if necessary.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(tenant_id) when is_binary(tenant_id) do
    case whereis(tenant_id) do
      nil ->
        start_for_tenant(tenant_id)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Returns the PID of the ZenRuleSync for a tenant, or nil if not running.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(tenant_id) when is_binary(tenant_id) do
    case TenantRegistry.lookup(tenant_id, {:zen_rule_sync, tenant_id}) do
      [{pid, _meta}] -> pid
      [] -> nil
    end
  end

  @doc """
  Starts ZenRuleSync for a tenant under the tenant's supervisor.
  """
  @spec start_for_tenant(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_for_tenant(tenant_id) when is_binary(tenant_id) do
    child_spec = %{
      id: {:zen_rule_sync, tenant_id},
      start: {__MODULE__, :start_link, [[tenant_id: tenant_id]]},
      type: :worker,
      restart: :transient
    }

    case TenantRegistry.start_child(tenant_id, child_spec) do
      {:ok, pid} ->
        Logger.info("Started ZenRuleSync for tenant", tenant_id: tenant_id)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start ZenRuleSync",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Syncs a rule to the KV store.
  """
  @spec sync_rule(ZenRule.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_rule(%ZenRule{} = rule, opts \\ []) do
    tenant_id = rule.tenant_id
    tenant_schema = Keyword.get(opts, :tenant_schema) || tenant_id

    if datasvc_available?() do
      sync_rule_impl(rule, tenant_schema)
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
  Triggers an immediate reconciliation for a tenant.
  """
  @spec reconcile(String.t()) :: :ok
  def reconcile(tenant_id) when is_binary(tenant_id) do
    case whereis(tenant_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reconcile)
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(tenant_id))
  end

  defp via_tuple(tenant_id) do
    {:via, Horde.Registry, {TenantRegistry.registry_name(tenant_id), {:zen_rule_sync, tenant_id}}}
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    Logger.info("ZenRuleSync starting", tenant_id: tenant_id)

    # Schedule first reconciliation
    Process.send_after(self(), :reconcile, @reconcile_delay_ms)

    # DB connection's search_path determines the schema
    {:ok, %__MODULE__{
      tenant_id: tenant_id,
      tenant_schema: tenant_id,
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
      reconcile_tenant(state)
    end
  end

  defp reconcile_tenant(state) do
    query = Ash.Query.for_read(ZenRule, :active, %{})

    case Ash.read(query, state.ash_opts) do
      {:ok, rules} ->
        Enum.each(rules, &sync_rule_with_logging(&1, state))

      {:error, reason} ->
        Logger.warning("Failed to load zen rules",
          tenant_id: state.tenant_id,
          reason: inspect(reason)
        )
    end
  end

  defp sync_rule_with_logging(rule, state) do
    case sync_rule_with_actor(rule, state) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Zen rule reconcile failed",
          tenant_id: state.tenant_id,
          rule_id: rule.id,
          reason: inspect(reason)
        )

        :ok

      unexpected ->
        Logger.warning("Zen rule reconcile returned unexpected result",
          tenant_id: state.tenant_id,
          rule_id: rule.id,
          result: inspect(unexpected)
        )

        :ok
    end
  rescue
    error ->
      Logger.error("Zen rule reconcile crashed",
        tenant_id: state.tenant_id,
        rule_id: rule.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # Internal sync with opts from GenServer state
  defp sync_rule_with_actor(%ZenRule{} = rule, state) do
    sync_rule_impl(rule, state.ash_opts)
  end

  defp sync_rule_impl(%ZenRule{} = rule, tenant_schema) when is_binary(tenant_schema) do
    # Create opts for public API calls that don't have GenServer state
    # DB connection's search_path determines the schema
    opts = [actor: SystemActor.system(:zen_rule_sync)]
    sync_rule_impl(rule, opts)
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
