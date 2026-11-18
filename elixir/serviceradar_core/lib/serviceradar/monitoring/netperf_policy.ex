defmodule ServiceRadar.Monitoring.NetperfPolicy do
  @moduledoc """
  Declarative Hub & Spoke or Hub-Mesh network performance policy.

  - `:hub_and_spoke`: enrolled agents matching `spoke_selector` test each attached
    enabled `NetperfResponder` (automatically excluding self-tests).
  - `:hub_mesh`: attached enabled `NetperfResponder` agents test each other
    pairwise (automatically excluding `self -> self`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Monitoring.NetperfPolicyResponder
  alias ServiceRadar.Monitoring.Validations.NetperfSpokeSelector
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo

  require Ash.Query

  @manage_check {ActorHasPermission, permission: "settings.networks.manage"}

  @fields [
    :name,
    :description,
    :enabled,
    :mode,
    :profile_id,
    :spoke_selector
  ]

  postgres do
    table "netperf_policies"
    repo Repo
    schema "platform"

    references do
      reference :profile, on_delete: :restrict
    end

    check_constraints do
      check_constraint :mode, "netperf_policies_mode_check",
        check: "mode IN ('hub_and_spoke', 'hub_mesh')",
        message: "must be hub_and_spoke or hub_mesh"

      check_constraint :authority_epoch, "netperf_policies_authority_epoch_check",
        check: "authority_epoch >= 1",
        message: "must be at least 1"
    end
  end

  code_interface do
    define :list, action: :read
    define :list_enabled, action: :enabled
    define :get_by_id, action: :by_id, args: [:id]
    define :create_policy, action: :create
    define :update_policy, action: :update
    define :enable_policy, action: :enable
    define :disable_policy, action: :disable
    define :delete_policy, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept @fields
      validate NetperfSpokeSelector
    end

    update :update do
      accept @fields
      validate NetperfSpokeSelector
      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      default :hub_and_spoke
      public? true
      constraints one_of: [:hub_and_spoke, :hub_mesh]
    end

    attribute :profile_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :spoke_selector, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :authority_epoch, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :profile, ServiceRadar.Monitoring.NetperfProfile do
      source_attribute :profile_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    has_many :policy_responders, NetperfPolicyResponder do
      destination_attribute :policy_id
      public? true
    end

    many_to_many :responders, ServiceRadar.Monitoring.NetperfResponder do
      through NetperfPolicyResponder
      source_attribute_on_join_resource :policy_id
      destination_attribute_on_join_resource :responder_id
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end

  @doc """
  Synchronizes the attached `NetperfResponder` IDs for a policy atomically inside a
  database transaction using `NetperfPolicyResponder` `:attach` and `:destroy`.
  """
  @spec sync_responders(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def sync_responders(policy_id, responder_ids, opts \\ [])
      when is_binary(policy_id) and is_list(responder_ids) do
    desired = responder_ids |> Enum.uniq() |> MapSet.new()

    fn ->
      case NetperfPolicyResponder.list_for_policy(policy_id, opts) do
        {:ok, existing} ->
          existing_by_responder = Map.new(existing, &{&1.responder_id, &1})

          for {responder_id, link} <- existing_by_responder,
              not MapSet.member?(desired, responder_id) do
            case NetperfPolicyResponder.detach_responder(link, opts) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          for responder_id <- desired,
              not Map.has_key?(existing_by_responder, responder_id) do
            case NetperfPolicyResponder.attach_responder(
                   %{policy_id: policy_id, responder_id: responder_id},
                   opts
                 ) do
              {:ok, _link} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
