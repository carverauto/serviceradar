defmodule ServiceRadar.Edge.AgentCommand do
  @moduledoc """
  Persistent lifecycle record for on-demand agent commands.

  Commands are stored for short-term audit and troubleshooting. Lifecycle is
  managed via AshStateMachine to ensure valid transitions.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  import Ash.Expr

  @command_fields [
    :command_type,
    :agent_id,
    :partition_id,
    :payload,
    :context,
    :ttl_seconds,
    :expires_at,
    :requested_by
  ]

  postgres do
    table("agent_commands")
    repo(ServiceRadar.Repo)
    schema("platform")
  end

  state_machine do
    initial_states([:queued])
    default_initial_state(:queued)
    state_attribute(:status)

    transitions do
      transition(:mark_sent, from: :queued, to: :sent)
      transition(:acknowledge, from: [:queued, :sent], to: :acknowledged)
      transition(:start, from: [:queued, :sent, :acknowledged], to: :running)
      transition(:complete, from: [:sent, :acknowledged, :running], to: :completed)
      transition(:fail, from: [:queued, :sent, :acknowledged, :running], to: :failed)
      transition(:expire, from: [:queued, :sent, :acknowledged, :running], to: :expired)
      transition(:cancel, from: [:queued, :sent, :acknowledged, :running], to: :canceled)
      transition(:mark_offline, from: [:queued, :sent], to: :offline)
    end
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:create_command, action: :create)
    define(:mark_sent, action: :mark_sent)
    define(:acknowledge, action: :acknowledge)
    define(:start, action: :start)
    define(:update_progress, action: :update_progress)
    define(:complete, action: :complete)
    define(:fail, action: :fail)
    define(:expire, action: :expire)
    define(:cancel, action: :cancel)
    define(:mark_offline, action: :mark_offline)
  end

  actions do
    defaults([:read, :destroy])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    create :create do
      accept(@command_fields)

      change(fn changeset, _context ->
        ttl = Ash.Changeset.get_attribute(changeset, :ttl_seconds) || 60

        expires_at =
          Ash.Changeset.get_attribute(changeset, :expires_at) ||
            DateTime.add(DateTime.utc_now(), ttl, :second)

        Ash.Changeset.change_attribute(changeset, :expires_at, expires_at)
      end)
    end

    update :mark_sent do
      accept([:partition_id])
      change(transition_state(:sent))
      change(set_attribute(:sent_at, &DateTime.utc_now/0))
    end

    update :acknowledge do
      argument(:message, :string)
      change(transition_state(:acknowledged))
      change(set_attribute(:acknowledged_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
    end

    update :start do
      argument(:message, :string)
      argument(:progress_percent, :integer)

      change(transition_state(:running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
      change(set_attribute(:last_progress_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
      change(set_attribute(:progress_percent, arg(:progress_percent)))
    end

    update :update_progress do
      argument(:message, :string)
      argument(:progress_percent, :integer)
      argument(:progress_payload, :map)

      change(set_attribute(:last_progress_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
      change(set_attribute(:progress_percent, arg(:progress_percent)))
      change(set_attribute(:progress_payload, arg(:progress_payload)))
    end

    update :complete do
      argument(:message, :string)
      argument(:result_payload, :map)

      change(transition_state(:completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
      change(set_attribute(:result_payload, arg(:result_payload)))
    end

    update :fail do
      argument(:message, :string)
      argument(:failure_reason, :string)
      argument(:result_payload, :map)

      change(transition_state(:failed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
      change(set_attribute(:failure_reason, arg(:failure_reason)))
      change(set_attribute(:result_payload, arg(:result_payload)))
    end

    update :expire do
      change(transition_state(:expired))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :cancel do
      argument(:message, :string)
      change(transition_state(:canceled))
      change(set_attribute(:canceled_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
    end

    update :mark_offline do
      argument(:message, :string)
      argument(:failure_reason, :string)

      change(transition_state(:offline))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:message, arg(:message)))
      change(set_attribute(:failure_reason, arg(:failure_reason)))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()

    policy action([
             :create,
             :mark_sent,
             :acknowledge,
             :start,
             :update_progress,
             :complete,
             :fail,
             :expire,
             :cancel,
             :mark_offline,
             :destroy
           ]) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  attributes do
    uuid_primary_key(:id, source: :command_id)

    attribute :command_type, :string do
      allow_nil?(false)
    end

    attribute :agent_id, :string do
      allow_nil?(false)
    end

    attribute :partition_id, :string do
      allow_nil?(false)
      default("default")
    end

    attribute :status, :atom do
      allow_nil?(false)

      constraints(
        one_of: [
          :queued,
          :sent,
          :acknowledged,
          :running,
          :completed,
          :failed,
          :expired,
          :canceled,
          :offline
        ]
      )

      default(:queued)
    end

    attribute(:payload, :map)
    attribute(:context, :map)
    attribute(:result_payload, :map)
    attribute(:progress_payload, :map)
    attribute(:message, :string)
    attribute(:failure_reason, :string)
    attribute(:progress_percent, :integer)

    attribute :ttl_seconds, :integer do
      default(60)
    end

    attribute(:expires_at, :utc_datetime)
    attribute(:sent_at, :utc_datetime)
    attribute(:acknowledged_at, :utc_datetime)
    attribute(:started_at, :utc_datetime)
    attribute(:last_progress_at, :utc_datetime)
    attribute(:completed_at, :utc_datetime)
    attribute(:canceled_at, :utc_datetime)

    attribute(:requested_by, :string)

    timestamps()
  end
end
