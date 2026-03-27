defmodule ServiceRadar.Edge.AgentReleaseTarget do
  @moduledoc """
  Per-agent rollout state for a desired agent release.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @target_fields [
    :rollout_id,
    :release_id,
    :agent_id,
    :cohort_index,
    :desired_version,
    :current_version,
    :command_id,
    :status,
    :progress_percent,
    :last_status_message,
    :last_error,
    :dispatched_at,
    :completed_at,
    :metadata
  ]

  @status_fields [
    :current_version,
    :command_id,
    :status,
    :progress_percent,
    :last_status_message,
    :last_error,
    :dispatched_at,
    :completed_at,
    :metadata
  ]

  postgres do
    table("agent_release_targets")
    repo(ServiceRadar.Repo)
    schema("platform")
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:get_by_command_id, action: :by_command_id, args: [:command_id])
    define(:create_target, action: :create)
    define(:set_status, action: :set_status)
  end

  actions do
    defaults([:read])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :by_command_id do
      argument(:command_id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(command_id == ^arg(:command_id)))
    end

    read :by_agent do
      argument(:agent_id, :string, allow_nil?: false)
      filter(expr(agent_id == ^arg(:agent_id)))
    end

    create :create do
      accept(@target_fields)
    end

    update :set_status do
      accept(@status_fields)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    operator_action([:create, :set_status])
  end

  identities do
    identity(:unique_rollout_agent, [:rollout_id, :agent_id])
  end

  relationships do
    belongs_to :rollout, ServiceRadar.Edge.AgentReleaseRollout do
      source_attribute(:rollout_id)
      destination_attribute(:id)
      allow_nil?(false)
      attribute_type(:uuid)
      public?(true)
    end

    belongs_to :release, ServiceRadar.Edge.AgentRelease do
      source_attribute(:release_id)
      destination_attribute(:id)
      allow_nil?(false)
      attribute_type(:uuid)
      public?(true)
    end
  end

  attributes do
    uuid_primary_key(:id, source: :target_id)

    attribute :agent_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :cohort_index, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :desired_version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :current_version, :string do
      public?(true)
    end

    attribute :command_id, :uuid do
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)

      constraints(
        one_of: [
          :pending,
          :dispatched,
          :downloading,
          :verifying,
          :staged,
          :restarting,
          :healthy,
          :failed,
          :rolled_back,
          :canceled
        ]
      )
    end

    attribute :progress_percent, :integer do
      public?(true)
    end

    attribute :last_status_message, :string do
      public?(true)
    end

    attribute :last_error, :string do
      public?(true)
    end

    attribute :dispatched_at, :utc_datetime do
      public?(true)
    end

    attribute :completed_at, :utc_datetime do
      public?(true)
    end

    attribute :metadata, :map do
      public?(true)
      default(%{})
    end

    timestamps()
  end
end
