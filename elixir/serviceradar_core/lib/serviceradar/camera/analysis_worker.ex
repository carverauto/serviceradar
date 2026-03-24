defmodule ServiceRadar.Camera.AnalysisWorker do
  @moduledoc """
  Platform-owned registry of camera analysis workers.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @mutable_fields [
    :display_name,
    :adapter,
    :endpoint_url,
    :capabilities,
    :enabled,
    :headers,
    :metadata
  ]

  postgres do
    table "camera_analysis_workers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_worker_id, action: :by_worker_id, args: [:worker_id]
    define :list_enabled, action: :enabled
    define :register_worker, action: :create
    define :update_worker, action: :update
    define :upsert_worker, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_worker_id do
      argument :worker_id, :string, allow_nil?: false
      get? true
      filter expr(worker_id == ^arg(:worker_id))
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [worker_id: :asc])
    end

    create :create do
      accept [
        :worker_id,
        :display_name,
        :adapter,
        :endpoint_url,
        :capabilities,
        :enabled,
        :headers,
        :metadata
      ]
    end

    update :update do
      accept @mutable_fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_worker_id

      accept [
        :worker_id,
        :display_name,
        :adapter,
        :endpoint_url,
        :capabilities,
        :enabled,
        :headers,
        :metadata
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :worker_id, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      public? true
    end

    attribute :adapter, :string do
      allow_nil? false
      public? true
      default "http"
    end

    attribute :endpoint_url, :string do
      allow_nil? false
      public? true
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :headers, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_worker_id, [:worker_id]
  end
end
