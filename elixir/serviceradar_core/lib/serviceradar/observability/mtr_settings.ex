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

  @networks_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission, permission: "settings.networks.manage"}

  @default_retention_days 30
  @mtr_tables ["mtr_traces", "mtr_hops"]

  postgres do
    table("mtr_settings")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  code_interface do
    define(:get_settings, action: :get_singleton)
    define(:create_settings, action: :create)
    define(:update_settings, action: :update)
  end

  actions do
    defaults([:read])

    read :get_singleton do
      get?(true)

      prepare(fn query, _ ->
        Ash.Query.limit(query, 1)
      end)
    end

    create :create do
      accept([
        :mtr_retention_days,
        :mtr_default_history_window,
        :mtr_history_page_size_default
      ])
    end

    update :update do
      accept([
        :mtr_retention_days,
        :mtr_default_history_window,
        :mtr_history_page_size_default
      ])
    end
  end

  policies do
    bypass always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:create, :update]) do
      authorize_if(@networks_manage_check)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :mtr_retention_days, :integer do
      allow_nil?(false)
      default(@default_retention_days)
      public?(true)
      constraints(min: 1, max: 395)
    end

    attribute :mtr_default_history_window, :string do
      allow_nil?(false)
      default("last_30d")
      public?(true)
    end

    attribute :mtr_history_page_size_default, :integer do
      allow_nil?(false)
      default(50)
      public?(true)
      constraints(min: 10, max: 200)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  @doc """
  Applies Timescale retention policies for MTR hypertables using configured days.
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
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      FOREACH table_name IN ARRAY ARRAY['mtr_traces', 'mtr_hops']
      LOOP
        table_ident := format('%I.%I', 'platform', table_name);

        IF EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'platform'
            AND hypertable_name = table_name
        ) THEN
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
        END IF;
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

    case read_policy_rows() do
      {:ok, rows} ->
        table_statuses =
          Map.new(@mtr_tables, fn table ->
            row = Enum.find(rows, &(Map.get(&1, "hypertable_name") == table))
            {table, policy_status(row, configured_days)}
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

  defp policy_status(nil, _configured_days), do: %{configured?: false, matches?: false}

  defp policy_status(%{"drop_after" => drop_after}, configured_days) do
    %{
      configured?: true,
      matches?: drop_after_matches?(drop_after, configured_days),
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
