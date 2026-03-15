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

  @netflow_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                         permission: "settings.netflow.manage"}

  postgres do
    table "netflow_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  cloak do
    vault(ServiceRadar.Vault)
    # AshCloak stores ciphertext in `encrypted_{attr}` and exposes the plaintext via `attr`.
    attributes([:ipinfo_api_key])
    decrypt_by_default([:ipinfo_api_key])
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :update_settings, action: :update
    define :update_enrichment_status, action: :update_enrichment_status
    define :create, action: :create
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true

      prepare fn query, _ ->
        query
        |> Ash.Query.limit(1)
        # Ensure the settings UI can render "token saved" state without needing
        # to decrypt or expose the token itself.
        |> Ash.Query.load([:ipinfo_api_key_present])
      end
    end

    create :create do
      accept [
        :geoip_enabled,
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
        |> maybe_set_secret(:ipinfo_api_key)
        |> maybe_clear_secret(:clear_ipinfo_api_key, :encrypted_ipinfo_api_key)
      end
    end

    update :update do
      require_atomic? false

      accept [
        :geoip_enabled,
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
        |> maybe_set_secret(:ipinfo_api_key)
        |> maybe_clear_secret(:clear_ipinfo_api_key, :encrypted_ipinfo_api_key)
      end
    end

    update :update_enrichment_status do
      description "System-only status updates for enrichment pipeline health."

      accept [
        :geolite_mmdb_last_attempt_at,
        :geolite_mmdb_last_success_at,
        :geolite_mmdb_last_error,
        :ip_enrichment_last_attempt_at,
        :ip_enrichment_last_success_at,
        :ip_enrichment_last_error
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if @netflow_manage_check
    end

    policy action([:create, :update]) do
      authorize_if @netflow_manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :geoip_enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

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

    # Encrypted at rest by AshCloak; ciphertext lives in `encrypted_ipinfo_api_key` (bytea).
    attribute :ipinfo_api_key, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "ipinfo.io token (encrypted at rest)"
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

    attribute :geolite_mmdb_last_attempt_at, :utc_datetime_usec do
      public? true
    end

    attribute :geolite_mmdb_last_success_at, :utc_datetime_usec do
      public? true
    end

    attribute :geolite_mmdb_last_error, :string do
      public? true
    end

    attribute :ip_enrichment_last_attempt_at, :utc_datetime_usec do
      public? true
    end

    attribute :ip_enrichment_last_success_at, :utc_datetime_usec do
      public? true
    end

    attribute :ip_enrichment_last_error, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :ipinfo_api_key_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        # Prefer checking the ciphertext field (generated by AshCloak), so we don't require
        # decrypting the token just to show "saved" state in the UI.
        case Map.get(record, :encrypted_ipinfo_api_key) do
          value when is_binary(value) -> byte_size(value) > 0
          _ -> false
        end
      end)
    end
  end

  defp maybe_set_secret(changeset, arg_name) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      nil ->
        changeset

      "" ->
        changeset

      value when is_binary(value) ->
        # Encrypt using the plaintext attribute name; AshCloak writes ciphertext to
        # `encrypted_{attr}` and removes the plaintext argument/param from the changeset.
        AshCloak.encrypt_and_set(changeset, arg_name, value)
    end
  end

  defp maybe_clear_secret(changeset, arg_name, encrypted_attr) do
    if Ash.Changeset.get_argument(changeset, arg_name) do
      Ash.Changeset.force_change_attribute(changeset, encrypted_attr, nil)
    else
      changeset
    end
  end
end
