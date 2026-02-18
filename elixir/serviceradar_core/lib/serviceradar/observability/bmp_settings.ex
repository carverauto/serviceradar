defmodule ServiceRadar.Observability.BmpSettings do
  @moduledoc """
  Deployment-level BMP/BGP ingestion and overlay settings (singleton).

  These settings control:
  - Raw BMP routing retention window
  - OCSF promotion threshold for BMP events
  - God-View causal overlay window/limits for routing events
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @type t :: %__MODULE__{}

  postgres do
    table "bmp_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :update_settings, action: :update
    define :create, action: :create
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
        :bmp_routing_retention_days,
        :bmp_ocsf_min_severity,
        :god_view_causal_overlay_window_seconds,
        :god_view_causal_overlay_max_events,
        :god_view_routing_causal_severity_threshold
      ]
    end

    update :update do
      accept [
        :bmp_routing_retention_days,
        :bmp_ocsf_min_severity,
        :god_view_causal_overlay_window_seconds,
        :god_view_causal_overlay_max_events,
        :god_view_routing_causal_severity_threshold
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.networks.manage"}
    end

    policy action([:create, :update]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.networks.manage"}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :bmp_routing_retention_days, :integer do
      allow_nil? false
      default 3
      public? true
      constraints min: 1, max: 30
    end

    attribute :bmp_ocsf_min_severity, :integer do
      allow_nil? false
      default 4
      public? true
      constraints min: 0, max: 6
    end

    attribute :god_view_causal_overlay_window_seconds, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 30, max: 3600
    end

    attribute :god_view_causal_overlay_max_events, :integer do
      allow_nil? false
      default 512
      public? true
      constraints min: 32, max: 10_000
    end

    attribute :god_view_routing_causal_severity_threshold, :integer do
      allow_nil? false
      default 4
      public? true
      constraints min: 0, max: 6
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc """
  Applies Timescale retention policy for `bmp_routing_events` using configured days.
  """
  @spec apply_routing_retention_policy(map()) :: :ok | {:error, term()}
  def apply_routing_retention_policy(%{bmp_routing_retention_days: days})
      when is_integer(days) do
    interval = "#{max(days, 1)} days"

    sql = """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', 'bmp_routing_events');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
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
    END;
    $$;
    """

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_routing_retention_policy(_), do: {:error, :invalid_settings}
end
