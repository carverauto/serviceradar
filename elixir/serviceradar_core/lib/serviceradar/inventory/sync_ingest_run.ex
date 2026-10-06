defmodule ServiceRadar.Inventory.SyncIngestRun do
  @moduledoc "Durable chunk receipts preventing activation of incomplete inventory runs."
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    # Composite-key receipt ledger is managed by the explicit migration.
    migrate? false
    table "sync_ingest_runs"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:sync_service_id, :sync_run_id, :received_chunks, :total_chunks, :incomplete]
    end

    update :record do
      accept [:received_chunks, :total_chunks, :incomplete]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :sync_service_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :sync_run_id, :string, primary_key?: true, allow_nil?: false
    attribute :received_chunks, {:array, :integer}, allow_nil?: false, default: []
    attribute :total_chunks, :integer, allow_nil?: false, default: 0
    attribute :incomplete, :boolean, allow_nil?: false, default: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
