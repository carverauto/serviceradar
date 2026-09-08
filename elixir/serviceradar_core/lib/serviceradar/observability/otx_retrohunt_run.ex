defmodule ServiceRadar.Observability.OTXRetrohuntRun do
  @moduledoc """
  Operator-triggered AlienVault OTX retrohunt runs.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "otx_retrohunt_runs"
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

    attribute :source, :string do
      allow_nil? false
      default "alienvault_otx"
      public? true
    end

    attribute :triggered_by, :string do
      allow_nil? false
      default "manual"
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "running"
      public? true
    end

    attribute :window_start, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :window_end, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    attribute :indicators_evaluated, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :findings_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :unsupported_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :error, :string do
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
