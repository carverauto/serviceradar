defmodule ServiceRadar.Integrations.IntegrationUpdateRunTarget do
  @moduledoc """
  Immutable per-source-ID disposition for one integration update run.

  These rows freeze the collection membership and outbound outcome so later
  source collections, merges, or repairs cannot rewrite a historical run.
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_update_run_targets"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_run, action: :by_run, args: [:integration_update_run_id]
  end

  actions do
    defaults [:read]

    read :by_run do
      argument :integration_update_run_id, :uuid, allow_nil?: false
      filter expr(integration_update_run_id == ^arg(:integration_update_run_id))
      prepare build(sort: [source_object_id: :asc])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_primary_key :id
    attribute :integration_update_run_id, :uuid, allow_nil?: false, public?: true
    attribute :collection_id, :string, allow_nil?: false, public?: true
    attribute :source_object_id, :string, allow_nil?: false, public?: true
    attribute :canonical_device_uid, :string, public?: true

    attribute :eligibility, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:eligible, :withheld]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :accepted, :failed, :unattempted, :withheld]
    end

    attribute :reason, :string, public?: true
    attribute :is_available, :boolean, public?: true

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  relationships do
    belongs_to :integration_update_run, ServiceRadar.Integrations.IntegrationUpdateRun do
      source_attribute :integration_update_run_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_run_source_object, [:integration_update_run_id, :source_object_id]
  end
end
