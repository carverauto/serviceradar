defmodule ServiceRadar.Observability.NetflowSettings do
  @moduledoc """
  Deployment-level NetFlow settings (singleton).

  This resource stores:
  - External enrichment provider settings (e.g. ipinfo.io/lite API token)
  - Optional security intelligence toggles and thresholds

  Sensitive fields are encrypted at rest using AshCloak/Cloak (`ServiceRadar.Vault`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:ipinfo_api_key])
    decrypt_by_default([:ipinfo_api_key])
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
        :ipinfo_enabled,
        :ipinfo_base_url,
        :threat_intel_enabled,
        :threat_intel_feed_urls,
        :anomaly_enabled,
        :anomaly_baseline_window_seconds,
        :anomaly_threshold_percent,
        :port_scan_enabled,
        :port_scan_window_seconds,
        :port_scan_unique_ports_threshold
      ]

      argument :ipinfo_api_key, :string do
        sensitive? true
        description "ipinfo.io token (will be encrypted)"
      end

      argument :clear_ipinfo_api_key, :boolean do
        default false
        description "When true, clears the stored ipinfo.io token"
      end

      change fn changeset, _ ->
        changeset
        |> maybe_set_secret(:ipinfo_api_key, :ipinfo_api_key)
        |> maybe_clear_secret(:clear_ipinfo_api_key, :ipinfo_api_key)
      end
    end

    update :update do
      require_atomic? false

      accept [
        :ipinfo_enabled,
        :ipinfo_base_url,
        :threat_intel_enabled,
        :threat_intel_feed_urls,
        :anomaly_enabled,
        :anomaly_baseline_window_seconds,
        :anomaly_threshold_percent,
        :port_scan_enabled,
        :port_scan_window_seconds,
        :port_scan_unique_ports_threshold
      ]

      argument :ipinfo_api_key, :string do
        sensitive? true
        description "ipinfo.io token (will be encrypted). Leave blank to keep existing."
      end

      argument :clear_ipinfo_api_key, :boolean do
        default false
        description "When true, clears the stored ipinfo.io token"
      end

      change fn changeset, _ ->
        changeset
        |> maybe_set_secret(:ipinfo_api_key, :ipinfo_api_key)
        |> maybe_clear_secret(:clear_ipinfo_api_key, :ipinfo_api_key)
      end
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.netflow.manage"}
    end

    policy action([:create, :update]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.netflow.manage"}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ipinfo_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :ipinfo_base_url, :string do
      allow_nil? false
      default "https://api.ipinfo.io"
      public? true
    end

    attribute :ipinfo_api_key, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted ipinfo.io token"
    end

    attribute :threat_intel_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :threat_intel_feed_urls, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :anomaly_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :anomaly_baseline_window_seconds, :integer do
      allow_nil? false
      default 604_800
      public? true
    end

    attribute :anomaly_threshold_percent, :integer do
      allow_nil? false
      default 300
      public? true
    end

    attribute :port_scan_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :port_scan_window_seconds, :integer do
      allow_nil? false
      default 300
      public? true
    end

    attribute :port_scan_unique_ports_threshold, :integer do
      allow_nil? false
      default 50
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :ipinfo_api_key_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        case Map.get(record, :ipinfo_api_key) do
          nil -> false
          "" -> false
          value when is_binary(value) -> byte_size(value) > 0
          _ -> true
        end
      end)
    end
  end

  defp maybe_set_secret(changeset, arg_name, encrypted_attr) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      nil -> changeset
      "" -> changeset
      value when is_binary(value) -> Ash.Changeset.change_attribute(changeset, encrypted_attr, value)
    end
  end

  defp maybe_clear_secret(changeset, arg_name, encrypted_attr) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      true -> Ash.Changeset.change_attribute(changeset, encrypted_attr, nil)
      _ -> changeset
    end
  end
end
