defmodule ServiceRadar.Cluster.TenantSchemas do
  @moduledoc """
  Manages PostgreSQL schemas for per-tenant data isolation (SOC2 compliance).

  This module provides physical data isolation at the database level using
  PostgreSQL schemas. Each tenant gets their own schema, ensuring:

  - Physical data separation for SOC2 compliance
  - Easy per-tenant backup/restore
  - Clear audit boundaries
  - Native PostgreSQL schema permissions

  ## Architecture

  ```
  PostgreSQL Database
  ├── public schema (shared)
  │   ├── tenants
  │   ├── users
  │   └── platform tables...
  │
  ├── tenant_acme_corp schema
  │   ├── devices
  │   ├── services
  │   └── tenant-specific tables...
  │
  └── tenant_xyz_inc schema
      ├── devices
      ├── services
      └── tenant-specific tables...
  ```

  ## Ash Integration

  For schema-isolated resources, use `strategy :context`:

  ```elixir
  defmodule ServiceRadar.Inventory.Device do
    use Ash.Resource,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "devices"
      repo ServiceRadar.Repo
    end

    multitenancy do
      strategy :context  # Uses tenant_<slug> schema
    end
  end
  ```

  For shared resources, use `strategy :attribute`:

  ```elixir
  defmodule ServiceRadar.Identity.Tenant do
    multitenancy do
      strategy :attribute
      attribute :id
      global? true
    end
  end
  ```

  ## Tiered Isolation

  Isolation level can vary by tenant plan:

  | Plan       | Strategy     | Description                        |
  |------------|--------------|-------------------------------------|
  | Enterprise | :context     | Full schema isolation               |
  | Pro        | :attribute   | Attribute-based with extra auditing |
  | Free       | :attribute   | Basic attribute-based               |

  ## Migration Strategy

  - Public schema migrations: `priv/repo/migrations/`
  - Tenant schema migrations: `priv/repo/tenant_migrations/`

  Run both during deployment:

  ```bash
  mix ecto.migrate
  mix ecto.migrate --migrations-path priv/repo/tenant_migrations --prefix tenant_*
  ```
  """

  alias ServiceRadar.Repo

  require Logger

  @tenant_prefix "tenant_"

  # ============================================================================
  # Schema Management
  # ============================================================================

  @doc """
  Creates a PostgreSQL schema for a tenant.

  ## Parameters

    - `tenant_slug` - Tenant slug (will be sanitized for schema name)
    - `opts` - Options
      - `:run_migrations` - Run tenant migrations after creation (default: true)

  ## Examples

      {:ok, "tenant_acme_corp"} = TenantSchemas.create_schema("acme-corp")
  """
  @spec create_schema(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_schema(tenant_slug, opts \\ []) do
    schema_name = schema_for(tenant_slug)
    run_migrations = Keyword.get(opts, :run_migrations, true)

    try do
      # Create schema (safe against injection via sanitized name)
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE SCHEMA IF NOT EXISTS #{schema_name}"
      )

      Logger.info("Created PostgreSQL schema: #{schema_name}")

      # Run tenant migrations if requested
      if run_migrations do
        run_tenant_migrations(schema_name)
      end

      {:ok, schema_name}
    rescue
      e in Postgrex.Error ->
        Logger.error("Failed to create schema #{schema_name}: #{inspect(e)}")
        {:error, {:postgres_error, e.postgres.message}}

      e ->
        Logger.error("Failed to create schema #{schema_name}: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Drops a PostgreSQL schema for a tenant.

  WARNING: This will DELETE ALL DATA in the schema. Use with extreme caution.

  ## Options

    - `:cascade` - Drop all objects in the schema (default: false)
    - `:if_exists` - Don't error if schema doesn't exist (default: true)
  """
  @spec drop_schema(String.t(), keyword()) :: :ok | {:error, term()}
  def drop_schema(tenant_slug, opts \\ []) do
    schema_name = schema_for(tenant_slug)
    cascade = if Keyword.get(opts, :cascade, false), do: "CASCADE", else: ""
    if_exists = if Keyword.get(opts, :if_exists, true), do: "IF EXISTS", else: ""

    try do
      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP SCHEMA #{if_exists} #{schema_name} #{cascade}"
      )

      Logger.warning("Dropped PostgreSQL schema: #{schema_name}")
      :ok
    rescue
      e in Postgrex.Error ->
        Logger.error("Failed to drop schema #{schema_name}: #{inspect(e)}")
        {:error, {:postgres_error, e.postgres.message}}
    end
  end

  @doc """
  Returns the PostgreSQL schema name for a tenant slug.

  Sanitizes the slug to ensure valid schema name.
  """
  @spec schema_for(String.t()) :: String.t()
  def schema_for(tenant_slug) do
    # Sanitize slug for schema name (alphanumeric + underscore only)
    safe_slug =
      tenant_slug
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")

    "#{@tenant_prefix}#{safe_slug}"
  end

  @doc """
  Checks if a tenant schema exists.
  """
  @spec schema_exists?(String.t()) :: boolean()
  def schema_exists?(tenant_slug) do
    schema_name = schema_for(tenant_slug)

    query = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.schemata
      WHERE schema_name = $1
    )
    """

    case Ecto.Adapters.SQL.query(Repo, query, [schema_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Lists all tenant schemas in the database.
  """
  @spec list_schemas() :: [String.t()]
  def list_schemas do
    query = """
    SELECT schema_name FROM information_schema.schemata
    WHERE schema_name LIKE $1
    ORDER BY schema_name
    """

    case Ecto.Adapters.SQL.query(Repo, query, ["#{@tenant_prefix}%"]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [name] -> name end)
      _ -> []
    end
  end

  @doc """
  Returns all tenant identifiers for migration purposes.

  This is the callback required by AshPostgres for schema-based multitenancy.
  It returns the list of all tenant schemas that need migrations run.
  """
  @spec all_tenants() :: [String.t()]
  def all_tenants do
    list_schemas()
  end

  # ============================================================================
  # Migration Management
  # ============================================================================

  @doc """
  Runs tenant migrations for a specific schema.
  """
  @spec run_tenant_migrations(String.t()) :: :ok | {:error, term()}
  def run_tenant_migrations(schema_name) do
    migrations_path = tenant_migrations_path()

    if File.dir?(migrations_path) do
      try do
        Ecto.Migrator.run(
          Repo,
          migrations_path,
          :up,
          all: true,
          prefix: schema_name
        )

        Logger.info("Ran tenant migrations for schema: #{schema_name}")
        :ok
      rescue
        e ->
          Logger.error("Failed to run migrations for #{schema_name}: #{inspect(e)}")
          {:error, e}
      end
    else
      Logger.debug("No tenant migrations directory found at #{migrations_path}")
      :ok
    end
  end

  @doc """
  Runs tenant migrations for all tenant schemas.
  """
  @spec run_all_tenant_migrations() :: :ok
  def run_all_tenant_migrations do
    for schema <- list_schemas() do
      run_tenant_migrations(schema)
    end

    :ok
  end

  @doc """
  Returns the path to tenant migrations.
  """
  @spec tenant_migrations_path() :: String.t()
  def tenant_migrations_path do
    Application.app_dir(:serviceradar_core, "priv/repo/tenant_migrations")
  end

  # ============================================================================
  # Repo Integration
  # ============================================================================

  @doc """
  Returns Ecto query options with the tenant schema prefix.

  Use this when making queries for tenant-specific data.

  ## Examples

      Repo.all(Device, TenantSchemas.query_opts("acme-corp"))
  """
  @spec query_opts(String.t()) :: keyword()
  def query_opts(tenant_slug) do
    [prefix: schema_for(tenant_slug)]
  end

  @doc """
  Executes a function within a tenant's schema context.

  Useful for complex operations that need multiple queries in the same schema.

  ## Examples

      TenantSchemas.with_tenant("acme-corp", fn ->
        Repo.all(Device)
        |> Enum.map(&process_device/1)
      end)
  """
  @spec with_tenant(String.t(), (-> result)) :: result when result: any()
  def with_tenant(tenant_slug, fun) do
    schema = schema_for(tenant_slug)
    previous = Process.get(:tenant_schema)

    try do
      Process.put(:tenant_schema, schema)
      fun.()
    after
      if previous do
        Process.put(:tenant_schema, previous)
      else
        Process.delete(:tenant_schema)
      end
    end
  end

  @doc """
  Gets the current tenant schema from process dictionary.

  Used by Repo callbacks to apply schema prefix.
  """
  @spec current_schema() :: String.t() | nil
  def current_schema do
    Process.get(:tenant_schema)
  end

  # ============================================================================
  # Isolation Level
  # ============================================================================

  @doc """
  Returns the isolation level for a tenant based on their plan.

  ## Examples

      TenantSchemas.isolation_level(%{plan: :enterprise})
      # => :context

      TenantSchemas.isolation_level(%{plan: :free})
      # => :attribute
  """
  @spec isolation_level(map() | struct()) :: :context | :attribute
  def isolation_level(%{plan: plan}) when plan in [:enterprise, "enterprise"] do
    :context
  end

  def isolation_level(_tenant) do
    :attribute
  end

  @doc """
  Determines if a tenant should use schema isolation.
  """
  @spec uses_schema_isolation?(map() | struct()) :: boolean()
  def uses_schema_isolation?(tenant) do
    isolation_level(tenant) == :context
  end
end
