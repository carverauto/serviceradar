defmodule ServiceRadar.Monitoring.NetperfPolicyResponder do
  @moduledoc """
  Join resource linking a `ServiceRadar.Monitoring.NetperfPolicy` to target
  `ServiceRadar.Monitoring.NetperfResponder` endpoints.

  Attaching or detaching a responder emits a `DependencyNotifier` event so
  affected `:netperf` agent configs are invalidated immediately.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "settings.networks.manage"}

  @fields [:policy_id, :responder_id]

  postgres do
    table "netperf_policy_responders"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_policy_responder: "netperf_policy_responders_uidx"

    references do
      reference :policy, on_delete: :delete
      reference :responder, on_delete: :delete
    end
  end

  code_interface do
    define :list_for_policy, action: :for_policy, args: [:policy_id]
    define :list_for_responder, action: :for_responder, args: [:responder_id]
    define :attach_responder, action: :attach
    define :detach_responder, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :for_policy do
      argument :policy_id, :uuid, allow_nil?: false
      filter expr(policy_id == ^arg(:policy_id))
    end

    read :for_responder do
      argument :responder_id, :uuid, allow_nil?: false
      filter expr(responder_id == ^arg(:responder_id))
    end

    create :create do
      accept @fields
    end

    create :attach do
      accept @fields
      upsert? true
      upsert_identity :unique_policy_responder
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :policy_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :responder_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :policy, ServiceRadar.Monitoring.NetperfPolicy do
      source_attribute :policy_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :responder, ServiceRadar.Monitoring.NetperfResponder do
      source_attribute :responder_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_policy_responder, [:policy_id, :responder_id]
  end
end
