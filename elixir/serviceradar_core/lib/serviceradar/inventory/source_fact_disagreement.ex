defmodule ServiceRadar.Inventory.SourceFactDisagreement do
  @moduledoc """
  Durable diagnostic when two inventory sources disagree on a platform fact.

  These rows are not retention-managed like `ocsf_events`. They stay until
  sources agree, one source drops out, or an operator dismisses them.
  They are not identity conflicts and do not withhold northbound updates.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "source_fact_disagreements"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_open, action: :open
  end

  actions do
    defaults [:read]

    read :open do
      filter expr(status == "open")
      prepare build(sort: [last_detected_at: :desc])
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [last_detected_at: :desc])
    end

    update :dismiss do
      change set_attribute(:status, "dismissed")
      change set_attribute(:dismissed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action(:dismiss)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string, allow_nil?: false, public?: true
    attribute :fact_key, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "open", public?: true
    attribute :compare_signature, :string, allow_nil?: false, public?: true

    attribute :values, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :configuration_conflict, :boolean, allow_nil?: false, default: false, public?: true
    attribute :first_detected_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_detected_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :cleared_at, :utc_datetime_usec, public?: true
    attribute :dismissed_at, :utc_datetime_usec, public?: true

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end
end
