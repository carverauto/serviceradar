defmodule ServiceRadar.CompositeChecks.DeviceCompositeCheckResult do
  @moduledoc """
  The current composite check verdict for one device.

  Verdicts live here rather than in `ocsf_devices.metadata` deliberately: a
  metadata merge per device per evaluation cycle would rewrite the device row on
  every pass, churning DIRE notifiers, device PubSub, and the device read model
  for data no device consumer needs inline.

  `changed_at` advances only when the verdict actually changes, so it is a real
  transition timestamp rather than a copy of `evaluated_at`.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @upsert_fields [
    :device_uid,
    :check_id,
    :verdict,
    :status,
    :matched_rule_id,
    :inputs,
    :evaluated_at,
    :changed_at
  ]

  postgres do
    table "device_composite_check_results"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete
    end

    custom_indexes do
      index [:device_uid], name: "device_composite_check_results_device_uid_idx"
      index [:check_id, :verdict], name: "device_composite_check_results_check_verdict_idx"
      index [:check_id, :status], name: "device_composite_check_results_check_status_idx"
      index [:check_id, :evaluated_at], name: "device_composite_check_results_check_eval_idx"
    end
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :list_by_check, action: :by_check, args: [:check_id]
    define :get_by_device_check, action: :by_device_check, args: [:device_uid, :check_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [evaluated_at: :desc])
    end

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [device_uid: :asc])
    end

    read :by_device_check do
      argument :device_uid, :string, allow_nil?: false
      argument :check_id, :uuid, allow_nil?: false
      get? true
      filter expr(device_uid == ^arg(:device_uid) and check_id == ^arg(:check_id))
    end

    create :upsert do
      accept @upsert_fields
      upsert? true
      upsert_identity :unique_device_check
      upsert_fields [:verdict, :status, :matched_rule_id, :inputs, :evaluated_at, :changed_at]
    end

    update :reassign_device do
      description "Repoint the row to a canonical device during an identity merge"
      accept [:device_uid]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :matched_rule_id, :uuid do
      public? true
    end

    attribute :inputs, :map do
      allow_nil? false
      default %{}
      public? true
      description "Per-input resolved value, observation time, and staleness at evaluation"
    end

    attribute :evaluated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :changed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the verdict last changed, not when it was last evaluated"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_device_check, [:device_uid, :check_id]
  end
end
