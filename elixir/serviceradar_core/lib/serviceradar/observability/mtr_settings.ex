defmodule ServiceRadar.Observability.MtrSettings do
  @moduledoc """
  Deployment-level MTR diagnostics settings.

  The persisted retention value is the source of truth for TimescaleDB retention
  policy reconciliation on `mtr_traces` and `mtr_hops`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @networks_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                          permission: "settings.networks.manage"}

  @default_retention_days 30
  @mtr_tables ["mtr_traces", "mtr_hops"]
  @max_automatic_migration_bytes 268_435_456

  postgres do
    table "mtr_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true

      prepare fn query, _ ->
        Ash.Query.limit(query, 1)
      end
    end

    create :create do
      accept [
        :mtr_retention_days,
        :mtr_default_history_window,
        :mtr_history_page_size_default
      ]
    end

    update :update do
      accept [
        :mtr_retention_days,
        :mtr_default_history_window,
        :mtr_history_page_size_default
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update]) do
      authorize_if @networks_manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :mtr_retention_days, :integer do
      allow_nil? false
      default @default_retention_days
      public? true
      constraints min: 1, max: 395
    end

    attribute :mtr_default_history_window, :string do
      allow_nil? false
      default "last_30d"
      public? true
    end

    attribute :mtr_history_page_size_default, :integer do
      allow_nil? false
      default 50
      public? true
      constraints min: 10, max: 200
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc """
  Converts `mtr_traces`/`mtr_hops` to hypertables when needed, then applies
  Timescale retention policies using the configured day count.

  Save used to return `:ok` while skipping regular tables, which left the
  settings UI showing "policy missing" after a successful save.
  """
  @spec apply_retention_policy(map()) :: :ok | {:error, term()}
  def apply_retention_policy(%{mtr_retention_days: days}) when is_integer(days) do
    interval = "#{days |> max(1) |> min(395)} days"

    sql = """
    DO $$
    DECLARE
      table_name text;
      table_ident text;
      ts_schema text;
      table_bytes bigint;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB extension is required for MTR retention policies';
      END IF;

      FOREACH table_name IN ARRAY ARRAY['mtr_traces', 'mtr_hops']
      LOOP
        table_ident := format('%I.%I', 'platform', table_name);

        IF to_regclass(table_ident) IS NULL THEN
          RAISE EXCEPTION 'required MTR table % is missing', table_ident;
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'platform'
            AND hypertable_name = table_name
        ) THEN
          SELECT pg_total_relation_size(table_ident::regclass)
          INTO table_bytes;

          IF table_bytes > #{@max_automatic_migration_bytes} THEN
            RAISE EXCEPTION
              '% is a regular table of % bytes; automatic hypertable conversion is limited to #{@max_automatic_migration_bytes} bytes',
              table_ident,
              table_bytes
              USING HINT = 'run create_hypertable during a maintenance window, then retry Save retention';
          END IF;

          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            table_ident,
            'time'
          );
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'platform'
            AND hypertable_name = table_name
        ) THEN
          RAISE EXCEPTION 'failed to convert % to a TimescaleDB hypertable', table_ident;
        END IF;

        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''%s'', if_not_exists => true)',
          ts_schema,
          table_ident,
          '#{interval}'
        );
      END LOOP;
    END;
    $$;
    """

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_retention_policy(_), do: {:error, :invalid_settings}

  @doc """
  Reads the current Timescale retention-policy status for MTR tables.
  """
  @spec retention_status(map() | nil) :: map()
  def retention_status(settings \\ nil) do
    configured_days = configured_days(settings)

    case read_table_states() do
      {:ok, {hypertables, rows}} ->
        table_statuses =
          Map.new(@mtr_tables, fn table ->
            row = Enum.find(rows, &(Map.get(&1, "hypertable_name") == table))
            {table, policy_status(row, MapSet.member?(hypertables, table), configured_days)}
          end)

        %{
          configured_days: configured_days,
          status: aggregate_status(table_statuses),
          tables: table_statuses
        }

      {:error, reason} ->
        %{
          configured_days: configured_days,
          status: :degraded,
          reason: inspect(reason),
          tables: %{}
        }
    end
  end

  def default_retention_days, do: @default_retention_days

  defp configured_days(%{mtr_retention_days: days}) when is_integer(days), do: days
  defp configured_days(_), do: @default_retention_days

  defp read_table_states do
    with {:ok, hypertables} <- read_hypertable_names(),
         {:ok, rows} <- read_policy_rows() do
      {:ok, {hypertables, rows}}
    end
  end

  defp read_hypertable_names do
    sql = """
    SELECT hypertable_name
    FROM timescaledb_information.hypertables
    WHERE hypertable_schema = 'platform'
      AND hypertable_name = ANY($1)
    """

    case ServiceRadar.Repo.query(sql, [@mtr_tables]) do
      {:ok, %{rows: rows}} ->
        {:ok, MapSet.new(rows, fn [name] -> name end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_policy_rows do
    sql = """
    SELECT hypertable_name, config ->> 'drop_after' AS drop_after
    FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_retention'
      AND hypertable_schema = 'platform'
      AND hypertable_name = ANY($1)
    """

    case ServiceRadar.Repo.query(sql, [@mtr_tables]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy_status(_row, false, _configured_days) do
    %{configured?: false, matches?: false, hypertable?: false}
  end

  defp policy_status(nil, true, _configured_days) do
    %{configured?: false, matches?: false, hypertable?: true}
  end

  defp policy_status(%{"drop_after" => drop_after}, true, configured_days) do
    %{
      configured?: true,
      matches?: drop_after_matches?(drop_after, configured_days),
      hypertable?: true,
      drop_after: drop_after
    }
  end

  defp drop_after_matches?(drop_after, days) when is_binary(drop_after) do
    normalized = String.downcase(drop_after)
    String.contains?(normalized, "#{days} day")
  end

  defp drop_after_matches?(_drop_after, _days), do: false

  defp aggregate_status(table_statuses) do
    values = Map.values(table_statuses)

    cond do
      values != [] and Enum.all?(values, & &1.matches?) -> :ok
      values != [] and Enum.all?(values, & &1.configured?) -> :mismatch
      true -> :missing
    end
  end
end
