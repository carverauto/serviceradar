defmodule ServiceRadar.Observability.NetflowPortScanFlag do
  @moduledoc """
  Cache table for port scan heuristic flags (per src_ip).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_port_scan_flags"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_src_ip do
      argument :src_ip, :string, allow_nil?: false
      filter expr(src_ip == ^arg(:src_ip))
    end

    create :upsert do
      accept [:src_ip, :unique_ports, :window_seconds, :window_end, :expires_at]

      upsert? true
      upsert_identity :unique_src_ip

      upsert_fields [:unique_ports, :window_seconds, :window_end, :expires_at, :updated_at]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:upsert) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:destroy) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :src_ip, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :unique_ports, :integer do
      allow_nil? false
      public? true
    end

    attribute :window_seconds, :integer do
      allow_nil? false
      public? true
    end

    attribute :window_end, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_src_ip, [:src_ip]
  end
end
