defmodule ServiceRadar.Observability.OTXRetrohuntFinding do
  @moduledoc """
  Deduplicated historical NetFlow findings for AlienVault OTX indicators.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Types.Cidr

  postgres do
    table "otx_retrohunt_findings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:destroy) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid do
      public? true
    end

    attribute :indicator_id, :uuid do
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      default "alienvault_otx"
      public? true
    end

    attribute :indicator, Cidr do
      allow_nil? false
      public? true
    end

    attribute :indicator_type, :string do
      allow_nil? false
      default "cidr"
      public? true
    end

    attribute :label, :string do
      public? true
    end

    attribute :severity, :integer do
      public? true
    end

    attribute :confidence, :integer do
      public? true
    end

    attribute :observed_ip, Cidr do
      allow_nil? false
      public? true
    end

    attribute :direction, :string do
      allow_nil? false
      public? true
    end

    attribute :first_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :evidence_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :bytes_total, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :packets_total, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
