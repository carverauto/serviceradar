defmodule ServiceRadar.CompositeChecks.ValidationRunDevice do
  @moduledoc """
  One target in an NCO validation run, with resolved uid and later verdict.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @execute_check {ActorHasPermission, permission: "validation_runs.execute"}
  @read_check {ActorHasPermission, permission: "validation_runs.read"}

  @create_fields [
    :run_id,
    :ip,
    :partition,
    :mac,
    :device_uid,
    :coverage,
    :verdict,
    :verdict_status,
    :inputs,
    :evaluated_at,
    :error
  ]

  postgres do
    table "validation_run_devices"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :run, on_delete: :delete
    end

    custom_indexes do
      index [:run_id], name: "validation_run_devices_run_id_idx"
      index [:device_uid], name: "validation_run_devices_device_uid_idx"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @create_fields
    end

    update :update do
      accept [
        :coverage,
        :verdict,
        :verdict_status,
        :inputs,
        :evaluated_at,
        :error
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@read_check)
    action_type_with_permission([:create, :update, :destroy], @execute_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :ip, :string do
      allow_nil? false
      public? true
    end

    attribute :partition, :string do
      allow_nil? false
      default "default"
      public? true
    end

    attribute :mac, :string do
      public? true
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :coverage, :map do
      allow_nil? false
      default %{}
      public? true
      description "Per-vantage-agent covering sweep group, profile, and probe state"
    end

    attribute :verdict, :string do
      public? true
    end

    attribute :verdict_status, :atom do
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :inputs, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :evaluated_at, :utc_datetime_usec do
      public? true
    end

    attribute :error, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :run, ServiceRadar.CompositeChecks.ValidationRun do
      allow_nil? false
      public? true
    end
  end
end
