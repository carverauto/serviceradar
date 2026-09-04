defmodule ServiceRadar.Inventory.Identity.ReconciliationRun do
  @moduledoc """
  One durable record per scheduled identity reconciliation run.

  `DuplicateSweep` builds a full summary of every run and, before this resource
  existed, logged it and discarded it. Two facts in particular were unrecoverable
  afterwards: whether the run stopped at its configured per-run merge cap, and
  whether it raised at all. See the migration
  `20260902100000_add_identity_reconciliation_runs` for the incident that made
  that expensive (GitHub #4229).

  Written only by the sweep, under the system actor. Readable by viewer-plus, and
  exposed to SRQL as `in:identity_reconciliation_runs` under `devices.view`.

  ## Writing must never fail the sweep

  Callers go through `DuplicateSweep`, which wraps every write here so a failure
  is logged and swallowed. That is deliberate and matches the reasoning already
  recorded for the device revival audit trigger: an audit that can reject the
  operation it observes gives somebody a motive to switch it off, and the bypass
  becomes the default. A missing run record is a worse diagnostic; a blocked
  reconciliation is an outage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @statuses [:completed, :failed]
  @triggers [:scheduled, :manual]

  @record_fields [
    :run_id,
    :started_at,
    :completed_at,
    :duration_ms,
    :status,
    :error_summary,
    :duplicate_identifier_count,
    :duplicate_components,
    :mergeable_components,
    :blocked_components,
    :blocked_devices,
    :largest_blocked_component,
    :merges,
    :errors,
    :max_merges_configured,
    :merge_cap_reached,
    :blocked_component_devices,
    :trigger,
    :job_schedule_id
  ]

  postgres do
    table "identity_reconciliation_runs"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :record, action: :record
    define :recent, action: :recent
    define :older_than, action: :older_than, args: [:cutoff]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Persist the summary of one reconciliation run"
      accept @record_fields
      upsert? true
      upsert_identity :unique_run
    end

    read :recent do
      description "Most recent reconciliation runs, newest first"
      prepare fn query, _context -> Ash.Query.sort(query, started_at: :desc) end
    end

    read :older_than do
      description "Runs started before the given cutoff, for retention pruning"
      argument :cutoff, :utc_datetime_usec, allow_nil?: false
      filter expr(started_at < ^arg(:cutoff))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    admin_action_type(:destroy)
  end

  attributes do
    attribute :run_id, :uuid do
      allow_nil? false
      primary_key? true
      writable? true
      public? true
      description "Identifier for this reconciliation run"
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :duration_ms, :integer, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: @statuses
      description "completed, or failed when the run raised and was rescued"
    end

    attribute :error_summary, :string, public?: true

    attribute :duplicate_identifier_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duplicate_components, :integer, allow_nil?: false, default: 0, public?: true
    attribute :mergeable_components, :integer, allow_nil?: false, default: 0, public?: true
    attribute :blocked_components, :integer, allow_nil?: false, default: 0, public?: true
    attribute :blocked_devices, :integer, allow_nil?: false, default: 0, public?: true

    attribute :largest_blocked_component, :integer do
      allow_nil? false
      default 0
      public? true
      description "Device count of the largest ambiguous component the run declined to merge"
    end

    attribute :merges, :integer, allow_nil?: false, default: 0, public?: true
    attribute :errors, :integer, allow_nil?: false, default: 0, public?: true

    attribute :max_merges_configured, :integer do
      public? true
      description "The per-run merge cap this run was given"
    end

    attribute :merge_cap_reached, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether the run stopped because it reached its configured merge cap"
    end

    attribute :blocked_component_devices, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Device uid membership of each blocked component, capped"
    end

    attribute :trigger, :atom do
      allow_nil? false
      default :scheduled
      public? true
      constraints one_of: @triggers
    end

    attribute :job_schedule_id, :integer, public?: true
  end

  identities do
    identity :unique_run, [:run_id]
  end

  @doc false
  def statuses, do: @statuses

  @doc false
  def triggers, do: @triggers
end
