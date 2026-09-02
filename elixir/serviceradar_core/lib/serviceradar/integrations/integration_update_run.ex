defmodule ServiceRadar.Integrations.IntegrationUpdateRun do
  @moduledoc """
  Persisted run history for integration-side update executions.

  Armis northbound jobs use this resource to record per-run status, counts,
  timestamps, and error details independently from inbound discovery status on
  the parent IntegrationSource.
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  @run_create_fields [:integration_source_id, :run_type, :oban_job_id, :metadata]
  @run_finalize_fields [
    :device_count,
    :updated_count,
    :skipped_count,
    :error_count,
    :eligible_count,
    :withheld_count,
    :accepted_count,
    :failed_count,
    :unattempted_count,
    :reconciliation_status,
    :error_message,
    :metadata
  ]

  @collection_fields [
    :collection_id,
    :collection_content_hash,
    :collection_observed_at,
    :raw_rows,
    :excluded_rows,
    :invalid_rows,
    :valid_occurrences,
    :distinct_source_ids,
    :duplicate_occurrences,
    :conflicting_duplicate_ids,
    :eligible_count,
    :withheld_count,
    :reconciliation_status,
    :metadata
  ]

  postgres do
    table "integration_update_runs"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:integration_source_id, :run_type],
        unique: true,
        name: "integration_update_runs_one_running_per_source_uidx",
        where: "status = 'running'"
    end
  end

  state_machine do
    initial_states [:running]
    default_initial_state :running
    state_attribute :status

    transitions do
      transition :finish_success, from: :running, to: :success
      transition :finish_partial, from: :running, to: :partial
      transition :finish_failed, from: :running, to: :failed
      transition :finish_timeout, from: :running, to: :timeout
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_source, action: :by_source, args: [:integration_source_id]
    define :list_recent_by_source, action: :recent_by_source, args: [:integration_source_id]
    define :get_latest_by_source, action: :latest_by_source, args: [:integration_source_id]
    define :get_by_oban_job_id, action: :by_oban_job_id, args: [:oban_job_id]
    define :start_run, action: :start_run
    define :finish_success, action: :finish_success
    define :finish_partial, action: :finish_partial
    define :finish_failed, action: :finish_failed
    define :finish_timeout, action: :finish_timeout
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_source do
      argument :integration_source_id, :uuid, allow_nil?: false

      filter expr(integration_source_id == ^arg(:integration_source_id))
      prepare build(sort: [started_at: :desc, inserted_at: :desc])
    end

    read :recent_by_source do
      argument :integration_source_id, :uuid, allow_nil?: false

      filter expr(integration_source_id == ^arg(:integration_source_id))
      prepare build(sort: [started_at: :desc, inserted_at: :desc], limit: 20)
    end

    read :latest_by_source do
      argument :integration_source_id, :uuid, allow_nil?: false
      get? true

      filter expr(integration_source_id == ^arg(:integration_source_id))
      prepare build(sort: [started_at: :desc, inserted_at: :desc], limit: 1)
    end

    read :by_oban_job_id do
      argument :oban_job_id, :integer, allow_nil?: false
      get? true

      filter expr(oban_job_id == ^arg(:oban_job_id))
      prepare build(sort: [inserted_at: :desc], limit: 1)
    end

    create :start_run do
      description "Create a running integration update record"
      accept @run_create_fields

      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :finish_success do
      description "Finalize an integration update run as successful"
      accept @run_finalize_fields

      change transition_state(:success)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :finish_partial do
      description "Finalize an integration update run as partially successful"
      accept @run_finalize_fields

      change transition_state(:partial)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :finish_failed do
      description "Finalize an integration update run as failed"
      accept @run_finalize_fields

      change transition_state(:failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :finish_timeout do
      description "Finalize an integration update run as timed out"
      accept @run_finalize_fields

      change transition_state(:timeout)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :bind_collection do
      description "Bind this run to one activated source collection"
      accept @collection_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    admin_action_type([:create, :update])
  end

  attributes do
    uuid_primary_key :id

    attribute :integration_source_id, :uuid do
      allow_nil? false
      public? true
      description "Owning integration source"
    end

    attribute :run_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:armis_northbound]
      description "Kind of integration update execution"
    end

    attribute :status, :atom do
      allow_nil? false
      default :running
      public? true
      constraints one_of: [:running, :success, :partial, :failed, :timeout]
      description "Current or final status for the run"
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
      description "When the run began"
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
      description "When the run completed"
    end

    attribute :device_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "Total devices considered during the run"
    end

    attribute :updated_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "Devices successfully updated during the run"
    end

    attribute :skipped_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "Devices skipped during the run"
    end

    attribute :error_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "Devices or batches that failed during the run"
    end

    attribute :collection_id, :string do
      public? true
      description "Activated source collection used by this run"
    end

    attribute :collection_content_hash, :string do
      public? true
      description "Content hash of the activated source collection"
    end

    attribute :collection_observed_at, :utc_datetime_usec do
      public? true
      description "Source observation time of the activated collection"
    end

    attribute :raw_rows, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :excluded_rows, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :invalid_rows, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :valid_occurrences, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :distinct_source_ids, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :duplicate_occurrences, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :conflicting_duplicate_ids, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :eligible_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :withheld_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :accepted_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :failed_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :unattempted_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :reconciliation_status, :atom do
      allow_nil? false
      default :unavailable
      public? true
      constraints one_of: [:unavailable, :pending, :reconciled, :degraded, :failed]
    end

    attribute :error_message, :string do
      public? true
      description "Summary error message for failed or partial runs"
    end

    attribute :oban_job_id, :integer do
      public? true
      description "Associated Oban job identifier when present"
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
      description "Additional run metadata"
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  relationships do
    belongs_to :integration_source, ServiceRadar.Integrations.IntegrationSource do
      source_attribute :integration_source_id
      destination_attribute :id
      public? true
      allow_nil? false
      define_attribute? false
    end
  end
end
