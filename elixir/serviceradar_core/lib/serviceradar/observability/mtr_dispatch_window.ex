defmodule ServiceRadar.Observability.MtrDispatchWindow do
  @moduledoc """
  Cooldown and dedupe ledger for automated MTR dispatch.

  Tracks most recent dispatch timestamps per target and trigger class so
  automated workers can suppress repeated fanout during flapping periods.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mtr_dispatch_windows"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :create_window, action: :create
    define :update_window, action: :update
  end

  actions do
    defaults [:read, :destroy]

    read :active_cooldowns do
      filter expr(not is_nil(cooldown_until) and cooldown_until > now())
    end

    create :create do
      accept [
        :target_key,
        :trigger_mode,
        :transition_class,
        :partition_id,
        :last_dispatched_at,
        :cooldown_until,
        :incident_correlation_id,
        :source_agent_ids,
        :dispatch_count
      ]
    end

    update :update do
      accept [
        :target_key,
        :trigger_mode,
        :transition_class,
        :partition_id,
        :last_dispatched_at,
        :cooldown_until,
        :incident_correlation_id,
        :source_agent_ids,
        :dispatch_count
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :target_key, :string do
      allow_nil? false
      public? true
    end

    attribute :trigger_mode, :string do
      allow_nil? false
      public? true
    end

    attribute :transition_class, :string do
      allow_nil? false
      default "none"
      public? true
    end

    attribute :partition_id, :string do
      public? true
    end

    attribute :last_dispatched_at, :utc_datetime_usec do
      public? true
    end

    attribute :cooldown_until, :utc_datetime_usec do
      public? true
    end

    attribute :incident_correlation_id, :string do
      public? true
    end

    attribute :source_agent_ids, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :dispatch_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
