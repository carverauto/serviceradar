defmodule ServiceRadar.Oban.SchemaValidator do
  @moduledoc """
  Validates that Oban tables exist in the expected PostgreSQL schema.

  This module is called after migrations run to ensure the `platform.oban_jobs`
  and `platform.oban_peers` tables exist before Oban processes start.

  ## Background

  Oban is configured with `prefix: "platform"` which means it expects tables
  in the `platform` schema. If migrations created tables in the wrong schema
  (e.g., `public`), Oban will fail with `undefined_table` errors.

  This validator catches that condition early with a clear error message
  and remediation steps.
  """

  require Logger

  @oban_schema "platform"
  @required_tables ["oban_jobs", "oban_peers"]

  @doc """
  Validates that all required Oban tables exist in the platform schema.

  Returns `:ok` if validation passes, or `{:error, reason}` with details.
  """
  @spec validate() :: :ok | {:error, String.t()}
  def validate do
    case check_tables() do
      {:ok, _} ->
        case check_migration_version() do
          :ok ->
            Logger.info(
              "[ObanSchemaValidator] Oban tables and schema version are current in #{@oban_schema}"
            )

            :ok

          {:error, message} ->
            Logger.error("[ObanSchemaValidator] #{message}")
            {:error, message}
        end

      {:error, missing} ->
        error_msg = build_error_message(missing)
        Logger.error("[ObanSchemaValidator] #{error_msg}")
        {:error, error_msg}
    end
  end

  @doc """
  Validates Oban schema, raising on failure.

  Use this in startup paths where failure should halt the application.
  """
  @spec validate!() :: :ok
  def validate! do
    case validate() do
      :ok -> :ok
      {:error, msg} -> raise RuntimeError, msg
    end
  end

  @doc """
  Checks if Oban tables exist and returns their status.

  Returns `{:ok, found_tables}` or `{:error, missing_tables}`.
  """
  @spec check_tables() :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check_tables do
    case get_existing_tables() do
      {:ok, existing} ->
        missing = @required_tables -- existing

        if Enum.empty?(missing) do
          {:ok, existing}
        else
          {:error, missing}
        end

      {:error, reason} ->
        Logger.error("[ObanSchemaValidator] Failed to query tables: #{inspect(reason)}")
        {:error, @required_tables}
    end
  end

  @doc false
  @spec migration_version_status(non_neg_integer() | :infinity, non_neg_integer()) ::
          :ok | {:error, String.t()}
  def migration_version_status(:infinity, _required), do: :ok
  def migration_version_status(version, version), do: :ok

  def migration_version_status(migrated, required)
      when is_integer(migrated) and is_integer(required) and migrated < required do
    {:error,
     "Oban schema in #{@oban_schema} is version #{migrated}, but runtime requires version #{required}. " <>
       "Run ServiceRadar database migrations before starting Oban."}
  end

  def migration_version_status(migrated, required)
      when is_integer(migrated) and is_integer(required) and migrated > required do
    {:error,
     "Oban schema in #{@oban_schema} is version #{migrated}, but runtime supports version #{required}. " <>
       "Deploy the matching ServiceRadar application version."}
  end

  def migration_version_status(migrated, required) do
    {:error,
     "Unable to compare Oban schema version #{inspect(migrated)} with runtime version #{inspect(required)}."}
  end

  @doc false
  @spec required_migration_version() :: non_neg_integer()
  def required_migration_version do
    Oban.Migration.current_version(repo: ServiceRadar.Repo)
  end

  @doc """
  Checks which schema(s) contain Oban tables.

  Useful for debugging schema placement issues.
  """
  @spec diagnose() :: %{platform: [String.t()], public: [String.t()]}
  def diagnose do
    platform_tables = get_tables_in_schema("platform")
    public_tables = get_tables_in_schema("public")

    %{
      platform: platform_tables,
      public: public_tables
    }
  end

  defp get_existing_tables do
    query = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = $1
      AND table_name IN ('oban_jobs', 'oban_peers')
    """

    case ServiceRadar.Repo.query(query, [@oban_schema]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [name] -> name end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_migration_version do
    migrated = Oban.Migration.migrated_version(prefix: @oban_schema, repo: ServiceRadar.Repo)
    required = required_migration_version()
    migration_version_status(migrated, required)
  end

  defp get_tables_in_schema(schema) do
    query = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = $1
      AND table_name LIKE 'oban%'
    """

    case ServiceRadar.Repo.query(query, [schema]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> name end)

      {:error, _} ->
        []
    end
  end

  defp build_error_message(missing_tables) do
    tables_str = Enum.join(missing_tables, ", ")
    diagnosis = diagnose()

    base_msg = """
    Oban tables missing from #{@oban_schema} schema: #{tables_str}

    This typically happens when migrations created Oban tables in the wrong schema.
    """

    location_hint =
      if Enum.any?(diagnosis.public) do
        """

        Found Oban tables in public schema: #{Enum.join(diagnosis.public, ", ")}
        The application expected tables in the '#{@oban_schema}' schema.

        To fix, run the following SQL:
          -- Copy tables from public to platform schema
          CREATE TABLE IF NOT EXISTS #{@oban_schema}.oban_jobs (LIKE public.oban_jobs INCLUDING ALL);
          CREATE TABLE IF NOT EXISTS #{@oban_schema}.oban_peers (LIKE public.oban_peers INCLUDING ALL);
        """
      else
        """

        No Oban tables found in any schema.

        To fix, ensure migrations run with SERVICERADAR_CORE_RUN_MIGRATIONS=true
        or manually run: mix ash.migrate
        """
      end

    base_msg <> location_hint
  end
end
