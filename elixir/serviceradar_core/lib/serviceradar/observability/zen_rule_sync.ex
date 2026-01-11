defmodule ServiceRadar.Observability.ZenRuleSync do
  @moduledoc """
  Synchronizes Zen rules to the datasvc KV store and reconciles on startup and interval.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Observability.ZenRule

  @reconcile_delay_ms 5_000
  @reconcile_interval_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :reconcile, @reconcile_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile_all()
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    {:noreply, state}
  end

  @spec sync_rule(ZenRule.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_rule(%ZenRule{} = rule, opts \\ []) do
    tenant_schema = Keyword.get(opts, :tenant_schema) || TenantSchemas.schema_for_tenant(rule.tenant_id)

    if not datasvc_available?() do
      {:error, :datasvc_unavailable}
    else
      sync_rule_with_kv(rule, tenant_schema)
    end
  end

  defp sync_rule_with_kv(%ZenRule{} = rule, tenant_schema) do
    if rule.enabled do
      key = kv_key(rule)
      payload = Jason.encode!(rule.compiled_jdm)

      with :ok <- Client.put(key, payload),
           {:ok, _value, revision} <- Client.get_with_revision(key),
           :ok <- update_kv_revision(rule, revision, tenant_schema) do
        {:ok, revision}
      end
    else
      case delete_rule(rule) do
        :ok -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec delete_rule(ZenRule.t()) :: :ok | {:error, term()}
  def delete_rule(%ZenRule{} = rule) do
    if datasvc_available?() do
      Client.delete(kv_key(rule))
    else
      {:error, :datasvc_unavailable}
    end
  end

  def kv_key(%ZenRule{} = rule) do
    "agents/#{rule.agent_id}/#{rule.stream_name}/#{rule.subject}/#{rule.name}.json"
  end

  def reconcile_all do
    if repo_enabled?() && datasvc_available?() do
      TenantSchemas.list_schemas()
      |> Enum.each(&reconcile_schema/1)
    end
  end

  defp reconcile_schema(schema) do
    query =
      ZenRule
      |> Ash.Query.for_read(:active, %{}, tenant: schema)

    case Ash.read(query, authorize?: false) do
      {:ok, rules} ->
        Enum.each(rules, fn rule ->
          case sync_rule(rule, tenant_schema: schema) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.warning("Zen rule reconcile failed: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to load zen rules for #{schema}: #{inspect(reason)}")
    end
  end

  defp update_kv_revision(%ZenRule{} = rule, revision, tenant_schema) do
    tenant_schema = tenant_schema || TenantSchemas.schema_for_tenant(rule.tenant_id)

    rule
    |> Ash.Changeset.for_update(:set_kv_revision, %{kv_revision: revision},
      tenant: tenant_schema,
      context: %{skip_zen_sync: true}
    )
    |> Ash.update(authorize?: false)
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
