defmodule ServiceRadar.Cluster.TenantRegistry do
  @moduledoc """
  Manages per-tenant Horde registries and DynamicSupervisors for multi-tenant process isolation.

  Each tenant gets their own:
  - Horde.Registry instance for process discovery
  - Horde.DynamicSupervisor for process supervision

  This ensures:
  - Edge components can only discover processes within their tenant
  - Cross-tenant process enumeration is prevented
  - Registry names are based on tenant UUIDs (not guessable slugs)
  - Slug-based aliases are available for debugging/admin

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    TenantRegistry (Supervisor)                   │
  │                                                                  │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │                    TenantSupervisor (T_abc123)               │ │
  │  │  ┌─────────────────┐  ┌─────────────────────────┐           │ │
  │  │  │ Horde.Registry  │  │ Horde.DynamicSupervisor │           │ │
  │  │  │ (T_abc123.Reg)  │  │ (T_abc123.Sup)          │           │ │
  │  │  │                 │  │                         │           │ │
  │  │  │ - pollers       │  │ - poller workers        │           │ │
  │  │  │ - agents        │  │ - agent workers         │           │ │
  │  │  └─────────────────┘  └─────────────────────────┘           │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  │                                                                  │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │                    TenantSupervisor (T_def456)               │ │
  │  │  ...                                                         │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Registry Lifecycle

  Tenant registries are created:
  1. On tenant creation (via Ash lifecycle hook)
  2. On first poller/agent connection (lazy initialization)

  ## Naming Convention

  - Registry: `ServiceRadar.TenantRegistry.T_<hash>.Registry`
  - Supervisor: `ServiceRadar.TenantRegistry.T_<hash>.Supervisor`
  - Hash is first 12 chars of SHA256(tenant_uuid) for security

  ## Slug Alias Lookup

  An ETS table maps tenant_slug -> tenant_id for admin/debug purposes:

      TenantRegistry.tenant_id_for_slug("acme-corp")
      # => "a1b2c3d4-..."

  ## Usage

  ```elixir
  # Ensure registry exists (lazy or explicit creation)
  {:ok, registry} = TenantRegistry.ensure_registry("tenant-uuid")

  # Register a poller
  TenantRegistry.register_poller("tenant-uuid", "poller-001", %{...})

  # Lookup within tenant's registry only
  TenantRegistry.lookup("tenant-uuid", {:poller, "poller-001"})

  # Start a process under tenant's supervisor
  TenantRegistry.start_child("tenant-uuid", child_spec)
  ```
  """

  use DynamicSupervisor

  require Logger

  @registry_prefix "ServiceRadar.TenantRegistry.T_"
  @slug_table :tenant_slug_to_id

  # ============================================================================
  # Supervisor API
  # ============================================================================

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS table for slug -> UUID mapping
    :ets.new(@slug_table, [:set, :public, :named_table, read_concurrency: true])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ============================================================================
  # Slug Alias Management
  # ============================================================================

  @doc """
  Registers a tenant slug -> UUID mapping for admin/debug lookups.

  Called when tenant is created or when registry is first initialized.
  """
  @spec register_slug(String.t(), String.t()) :: :ok
  def register_slug(tenant_slug, tenant_id) when is_binary(tenant_slug) and is_binary(tenant_id) do
    :ets.insert(@slug_table, {tenant_slug, tenant_id})
    :ok
  end

  @doc """
  Looks up tenant UUID from slug.

  Returns `{:ok, tenant_id}` or `:error` if not found.
  """
  @spec tenant_id_for_slug(String.t()) :: {:ok, String.t()} | :error
  def tenant_id_for_slug(tenant_slug) when is_binary(tenant_slug) do
    case :ets.lookup(@slug_table, tenant_slug) do
      [{^tenant_slug, tenant_id}] -> {:ok, tenant_id}
      [] -> :error
    end
  end

  @doc """
  Looks up tenant slug from UUID.

  This is less efficient (table scan) - use sparingly for admin purposes.
  """
  @spec slug_for_tenant_id(String.t()) :: {:ok, String.t()} | :error
  def slug_for_tenant_id(tenant_id) when is_binary(tenant_id) do
    result =
      :ets.foldl(
        fn {slug, id}, acc ->
          if id == tenant_id, do: slug, else: acc
        end,
        nil,
        @slug_table
      )

    case result do
      nil -> :error
      slug -> {:ok, slug}
    end
  end

  # ============================================================================
  # Registry Management
  # ============================================================================

  @doc """
  Ensures a tenant's registry and supervisor exist, creating them if necessary.

  Returns `{:ok, %{registry: atom(), supervisor: atom()}}`.
  """
  @spec ensure_registry(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_registry(tenant_id) when is_binary(tenant_id) do
    registry_name = registry_name(tenant_id)
    supervisor_name = supervisor_name(tenant_id)

    case Process.whereis(registry_name) do
      nil ->
        start_tenant_infrastructure(tenant_id)

      _pid ->
        {:ok, %{registry: registry_name, supervisor: supervisor_name}}
    end
  end

  @doc """
  Ensures a tenant's registry exists, optionally registering slug alias.

  Use this when you have both tenant_id and tenant_slug.
  """
  @spec ensure_registry(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def ensure_registry(tenant_id, tenant_slug) when is_binary(tenant_id) do
    if tenant_slug, do: register_slug(tenant_slug, tenant_id)
    ensure_registry(tenant_id)
  end

  @doc """
  Returns the registry module name for a tenant.

  Uses a hash of the tenant UUID for the name to prevent enumeration.
  """
  @spec registry_name(String.t()) :: atom()
  def registry_name(tenant_id) when is_binary(tenant_id) do
    String.to_atom("#{base_name(tenant_id)}.Registry")
  end

  @doc """
  Returns the supervisor module name for a tenant.
  """
  @spec supervisor_name(String.t()) :: atom()
  def supervisor_name(tenant_id) when is_binary(tenant_id) do
    String.to_atom("#{base_name(tenant_id)}.Supervisor")
  end

  defp base_name(tenant_id) do
    # Use first 12 chars of SHA256 hash for shorter but unique names
    hash =
      :crypto.hash(:sha256, tenant_id)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    "#{@registry_prefix}#{hash}"
  end

  @doc """
  Starts the full tenant infrastructure (registry + supervisor).
  """
  @spec start_tenant_infrastructure(String.t()) :: {:ok, map()} | {:error, term()}
  def start_tenant_infrastructure(tenant_id) do
    registry_name = registry_name(tenant_id)
    supervisor_name = supervisor_name(tenant_id)

    # Create a supervisor that manages both the registry and DynamicSupervisor
    child_spec = %{
      id: base_name(tenant_id),
      start:
        {__MODULE__.TenantSupervisor, :start_link,
         [
           [
             tenant_id: tenant_id,
             registry_name: registry_name,
             supervisor_name: supervisor_name
           ]
         ]},
      type: :supervisor,
      restart: :permanent
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} ->
        Logger.info("Started tenant infrastructure for tenant: #{tenant_id}")
        {:ok, %{registry: registry_name, supervisor: supervisor_name}}

      {:error, {:already_started, _pid}} ->
        {:ok, %{registry: registry_name, supervisor: supervisor_name}}

      {:error, reason} = error ->
        Logger.error("Failed to start tenant infrastructure for #{tenant_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops a tenant's infrastructure (e.g., when tenant is deleted).
  """
  @spec stop_tenant_infrastructure(String.t()) :: :ok | {:error, :not_found}
  def stop_tenant_infrastructure(tenant_id) do
    registry_name = registry_name(tenant_id)

    case Process.whereis(registry_name) do
      nil ->
        {:error, :not_found}

      _pid ->
        # Find and terminate the tenant supervisor
        base = base_name(tenant_id)

        # Child id matches the string we passed in start_tenant_infrastructure
        Enum.find(DynamicSupervisor.which_children(__MODULE__), fn {id, _, _, _} ->
          id == base
        end)
        |> case do
          {_id, pid, _, _} ->
            DynamicSupervisor.terminate_child(__MODULE__, pid)
            Logger.info("Stopped tenant infrastructure: #{base}")
            :ok

          nil ->
            {:error, :not_found}
        end
    end
  end

  # Legacy compatibility
  @doc false
  def start_tenant_registry(tenant_id) do
    case ensure_registry(tenant_id) do
      {:ok, %{registry: name}} -> {:ok, name}
      error -> error
    end
  end

  # Legacy compatibility
  @doc false
  def stop_tenant_registry(tenant_id) do
    stop_tenant_infrastructure(tenant_id)
  end

  @doc """
  Lists all active tenant registries.
  """
  @spec list_registries() :: [{atom(), pid()}]
  def list_registries do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      # Get the children of each tenant supervisor
      case Supervisor.which_children(pid) do
        children when is_list(children) ->
          Enum.filter(children, fn {id, _, _, _} ->
            String.ends_with?(to_string(id), ".Registry")
          end)
          |> Enum.map(fn {id, child_pid, _, _} -> {id, child_pid} end)

        _ ->
          []
      end
    end)
  rescue
    _ -> []
  end

  # ============================================================================
  # Child Process Management (DynamicSupervisor)
  # ============================================================================

  @doc """
  Starts a child process under the tenant's DynamicSupervisor.
  """
  @spec start_child(String.t(), Supervisor.child_spec()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(tenant_id, child_spec) do
    with {:ok, %{supervisor: sup_name}} <- ensure_registry(tenant_id) do
      Horde.DynamicSupervisor.start_child(sup_name, child_spec)
    end
  end

  @doc """
  Terminates a child process under the tenant's DynamicSupervisor.
  """
  @spec terminate_child(String.t(), pid()) :: :ok | {:error, :not_found}
  def terminate_child(tenant_id, pid) do
    supervisor_name = supervisor_name(tenant_id)

    if Process.whereis(supervisor_name) do
      Horde.DynamicSupervisor.terminate_child(supervisor_name, pid)
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # Registration API
  # ============================================================================

  @doc """
  Registers a process in a tenant's registry.

  ## Parameters

    - `tenant_id` - Tenant UUID
    - `key` - Registration key (e.g., `{:poller, "poller-001"}`)
    - `metadata` - Process metadata

  ## Examples

      TenantRegistry.register("tenant-uuid", {:poller, "poller-001"}, %{
        partition_id: "partition-1",
        node: node(),
        status: :available
      })
  """
  @spec register(String.t(), term(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register(tenant_id, key, metadata) do
    with {:ok, %{registry: registry}} <- ensure_registry(tenant_id) do
      Horde.Registry.register(registry, key, metadata)
    end
  end

  @doc """
  Unregisters a process from a tenant's registry.
  """
  @spec unregister(String.t(), term()) :: :ok
  def unregister(tenant_id, key) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      Horde.Registry.unregister(name, key)
    else
      :ok
    end
  end

  @doc """
  Updates metadata for a registered process.
  """
  @spec update_value(String.t(), term(), (map() -> map())) ::
          {any(), any()} | :error
  def update_value(tenant_id, key, callback) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      Horde.Registry.update_value(name, key, callback)
    else
      :error
    end
  end

  # ============================================================================
  # Lookup API
  # ============================================================================

  @doc """
  Looks up a process in a tenant's registry.

  Returns `[{pid, metadata}]` or `[]` if not found.
  """
  @spec lookup(String.t(), term()) :: [{pid(), map()}]
  def lookup(tenant_id, key) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      Horde.Registry.lookup(name, key)
    else
      []
    end
  end

  @doc """
  Selects processes from a tenant's registry by type.

  ## Parameters

    - `tenant_id` - Tenant UUID
    - `type` - Process type atom (`:poller`, `:agent`, `:checker`)

  ## Examples

      # Find all pollers for a tenant
      TenantRegistry.select_by_type("tenant-uuid", :poller)
  """
  @spec select_by_type(String.t(), atom()) :: [{term(), pid(), map()}]
  def select_by_type(tenant_id, type) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      # Match keys that start with the type atom
      match_spec = [
        {{{type, :"$1"}, :"$2", :"$3"}, [], [{{{{type, :"$1"}}, :"$2", :"$3"}}]}
      ]

      Horde.Registry.select(name, match_spec)
    else
      []
    end
  end

  @doc """
  Selects all processes from a tenant's registry.
  """
  @spec select_all(String.t()) :: [{term(), pid(), map()}]
  def select_all(tenant_id) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      Horde.Registry.select(name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    else
      []
    end
  end

  @doc """
  Counts processes in a tenant's registry.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) do
    name = registry_name(tenant_id)

    if Process.whereis(name) do
      Horde.Registry.count(name)
    else
      0
    end
  end

  @doc """
  Counts processes of a specific type in a tenant's registry.
  """
  @spec count_by_type(String.t(), atom()) :: non_neg_integer()
  def count_by_type(tenant_id, type) do
    select_by_type(tenant_id, type) |> length()
  end

  # ============================================================================
  # Convenience Functions for Pollers/Agents
  # ============================================================================

  @doc """
  Registers a poller in the tenant's registry.
  """
  @spec register_poller(String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, term()}
  def register_poller(tenant_id, poller_id, metadata) do
    full_metadata =
      metadata
      |> Map.put(:type, :poller)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register(tenant_id, {:poller, poller_id}, full_metadata)
  end

  @doc """
  Registers an agent in the tenant's registry.
  """
  @spec register_agent(String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, term()}
  def register_agent(tenant_id, agent_id, metadata) do
    full_metadata =
      metadata
      |> Map.put(:type, :agent)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register(tenant_id, {:agent, agent_id}, full_metadata)
  end

  @doc """
  Finds all pollers for a tenant.
  """
  @spec find_pollers(String.t()) :: [map()]
  def find_pollers(tenant_id) do
    select_by_type(tenant_id, :poller)
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Finds all agents for a tenant.
  """
  @spec find_agents(String.t()) :: [map()]
  def find_agents(tenant_id) do
    select_by_type(tenant_id, :agent)
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Finds available pollers for a tenant.
  """
  @spec find_available_pollers(String.t()) :: [map()]
  def find_available_pollers(tenant_id) do
    find_pollers(tenant_id)
    |> Enum.filter(&(&1[:status] == :available))
  end

  @doc """
  Updates heartbeat for a poller.
  """
  @spec poller_heartbeat(String.t(), String.t()) :: :ok | :error
  def poller_heartbeat(tenant_id, poller_id) do
    case update_value(tenant_id, {:poller, poller_id}, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end
end

defmodule ServiceRadar.Cluster.TenantRegistry.TenantSupervisor do
  @moduledoc """
  Supervisor for a single tenant's Horde registry and DynamicSupervisor.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    registry_name = Keyword.fetch!(opts, :registry_name)
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)

    children = [
      # Per-tenant Horde Registry for process discovery
      {Horde.Registry,
       name: registry_name,
       keys: :unique,
       members: :auto,
       delta_crdt_options: [sync_interval: 100]},

      # Per-tenant Horde DynamicSupervisor for process management
      {Horde.DynamicSupervisor,
       name: supervisor_name,
       strategy: :one_for_one,
       members: :auto,
       delta_crdt_options: [sync_interval: 100]}
    ]

    # Store tenant_id in process dictionary for debugging
    Process.put(:tenant_id, tenant_id)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
