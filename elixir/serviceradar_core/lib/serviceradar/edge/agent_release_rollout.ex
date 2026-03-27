defmodule ServiceRadar.Edge.AgentReleaseRollout do
  @moduledoc """
  Desired-version rollout plan for a cohort of agents.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @rollout_fields [
    :release_id,
    :desired_version,
    :cohort_agent_ids,
    :batch_size,
    :batch_delay_seconds,
    :status,
    :created_by,
    :started_at,
    :paused_at,
    :completed_at,
    :canceled_at,
    :last_dispatch_at,
    :notes,
    :metadata
  ]

  postgres do
    table("agent_release_rollouts")
    repo(ServiceRadar.Repo)
    schema("platform")
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:create_rollout, action: :create)
    define(:pause, action: :pause)
    define(:resume, action: :resume)
    define(:cancel, action: :cancel)
    define(:complete, action: :complete)
    define(:touch_dispatch, action: :touch_dispatch)
  end

  actions do
    defaults([:read])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :active do
      filter(expr(status == :active))
    end

    create :create do
      accept(@rollout_fields)

      change(fn changeset, _context ->
        changeset
        |> ensure_status()
        |> ensure_started_at()
      end)
    end

    update :pause do
      accept([])
      change(set_attribute(:status, :paused))
      change(set_attribute(:paused_at, &DateTime.utc_now/0))
    end

    update :resume do
      accept([])
      change(set_attribute(:status, :active))
      change(set_attribute(:paused_at, nil))
    end

    update :cancel do
      accept([])
      change(set_attribute(:status, :canceled))
      change(set_attribute(:canceled_at, &DateTime.utc_now/0))
    end

    update :complete do
      accept([])
      change(set_attribute(:status, :completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :touch_dispatch do
      accept([])
      change(set_attribute(:last_dispatch_at, &DateTime.utc_now/0))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    operator_action([:create, :pause, :resume, :cancel, :complete, :touch_dispatch])
  end

  relationships do
    belongs_to :release, ServiceRadar.Edge.AgentRelease do
      source_attribute(:release_id)
      destination_attribute(:id)
      allow_nil?(false)
      attribute_type(:uuid)
      public?(true)
    end
  end

  attributes do
    uuid_primary_key(:id, source: :rollout_id)

    attribute :desired_version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :cohort_agent_ids, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :batch_size, :integer do
      allow_nil?(false)
      public?(true)
      default(1)
    end

    attribute :batch_delay_seconds, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:active)
      constraints(one_of: [:active, :paused, :completed, :canceled])
    end

    attribute :created_by, :string do
      public?(true)
    end

    attribute :started_at, :utc_datetime do
      public?(true)
    end

    attribute :paused_at, :utc_datetime do
      public?(true)
    end

    attribute :completed_at, :utc_datetime do
      public?(true)
    end

    attribute :canceled_at, :utc_datetime do
      public?(true)
    end

    attribute :last_dispatch_at, :utc_datetime do
      public?(true)
    end

    attribute :notes, :string do
      public?(true)
    end

    attribute :metadata, :map do
      public?(true)
      default(%{})
    end

    timestamps()
  end

  defp ensure_status(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) do
      nil -> Ash.Changeset.change_attribute(changeset, :status, :active)
      _status -> changeset
    end
  end

  defp ensure_started_at(changeset) do
    case {Ash.Changeset.get_attribute(changeset, :status),
          Ash.Changeset.get_attribute(changeset, :started_at)} do
      {:active, nil} -> Ash.Changeset.change_attribute(changeset, :started_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
