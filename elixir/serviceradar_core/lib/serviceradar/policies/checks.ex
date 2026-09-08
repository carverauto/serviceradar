defmodule ServiceRadar.Policies.Checks do
  @moduledoc """
  Reusable Ash policy checks for ServiceRadar authorization.

  # DB connection's search_path determines the schema

  These checks can be used in policy definitions:

      policies do
        policy action_type(:read) do
          authorize_if ServiceRadar.Policies.Checks.ActorHasRole, role: :admin
        end
      end
  """

  alias Ash.Policy.Authorizer
  alias Ash.Policy.SimpleCheck

  defmodule ActorHasRole do
    @moduledoc """
    Check if the actor has a specific role.

    ## Options

      * `:role` - The required role (atom)
      * `:roles` - List of acceptable roles (list of atoms)

    ## Examples

        authorize_if {ServiceRadar.Policies.Checks.ActorHasRole, role: :admin}
        authorize_if {ServiceRadar.Policies.Checks.ActorHasRole, roles: [:admin, :operator]}
    """
    use SimpleCheck

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      role = Keyword.get(opts, :role)
      roles = Keyword.get(opts, :roles, [role])
      "actor has role in #{inspect(roles)}"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    # Ash may call match?/3 with the authorizer as the 2nd arg and the opts as the 3rd arg.
    # Normalize that shape so our checks don't crash.
    def match?(actor, %Authorizer{}, opts) when is_list(opts) do
      match?(actor, opts, %{})
    end

    def match?(actor, opts, _context) do
      opts = if is_list(opts), do: opts, else: []
      role = Keyword.get(opts, :role)
      roles = Keyword.get(opts, :roles, if(role, do: [role], else: []))

      actor_role = get_role(actor)
      actor_role in roles
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorIsAdmin do
    @moduledoc """
    Check if the actor is an admin.
    """
    use SimpleCheck

    @impl true
    def describe(_opts), do: "actor is admin"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, _context) do
      get_role(actor) == :admin
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorIsOperator do
    @moduledoc """
    Check if the actor is an operator or admin.
    """
    use SimpleCheck

    @impl true
    def describe(_opts), do: "actor is operator or admin"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, _context) do
      get_role(actor) in [:operator, :admin]
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorOwnsResource do
    @moduledoc """
    Check if the actor owns the resource (user_id matches).

    ## Options

      * `:attribute` - The attribute to check (default: :user_id)
    """
    use SimpleCheck

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      "actor owns resource (#{attr} matches)"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    # Ash may call match?/3 with the authorizer as the 2nd arg and the opts as the 3rd arg.
    # When that happens, use the authorizer's changeset as the context.
    def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
      match?(actor, opts, %{changeset: Map.get(authorizer, :changeset)})
    end

    def match?(actor, opts, %{changeset: %{data: resource}}) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      actor_id = Map.get(actor, :id)
      resource_owner = Map.get(resource, attr)

      actor_id != nil && actor_id == resource_owner
    end

    def match?(_actor, _opts, _context), do: false
  end

  defmodule ActorOwnsResourceUnlessPolicyAllows do
    @moduledoc """
    Check if the actor owns the resource unless a resource policy flag explicitly allows it.

    ## Options

      * `:attribute` - The owner attribute to check (default: :user_id)
      * `:policy_attribute` - The map attribute carrying the policy (default: :policy)
      * `:allow_key` - The boolean map key that allows ownership (default: "allow_self")
    """
    use SimpleCheck

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      policy_attr = Keyword.get(opts, :policy_attribute, :policy)
      allow_key = Keyword.get(opts, :allow_key, "allow_self")

      "actor owns #{attr} unless #{policy_attr}.#{allow_key} allows it"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
      match?(actor, opts, %{changeset: Map.get(authorizer, :changeset)})
    end

    def match?(actor, opts, %{changeset: %{data: resource}}) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      policy_attr = Keyword.get(opts, :policy_attribute, :policy)
      allow_key = Keyword.get(opts, :allow_key, "allow_self")
      actor_id = Map.get(actor, :id)
      resource_owner = Map.get(resource, attr)

      actor_id != nil && actor_id == resource_owner &&
        not policy_allows?(Map.get(resource, policy_attr), allow_key)
    end

    def match?(_actor, _opts, _context), do: false

    defp policy_allows?(policy, key) when is_map(policy) do
      Map.get(policy, key) == true || Map.get(policy, safe_atom_key(key)) == true
    end

    defp policy_allows?(_policy, _key), do: false

    defp safe_atom_key(key) when is_atom(key), do: key

    defp safe_atom_key(key) when is_binary(key) do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defmodule ActorSelfApprovesResource do
    @moduledoc """
    Check if the current actor is approving their own resource.

    This is intended for review/approval actions where caller identity, not only
    a writable `approved_by` attribute, must be bound to the resource requester.
    """
    use SimpleCheck

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      requester_attr = Keyword.get(opts, :requester_attribute, :requested_by)
      approver_attr = Keyword.get(opts, :approver_attribute, :approved_by)
      "actor self-approves resource (#{approver_attr} for #{requester_attr})"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
      match?(actor, opts, %{changeset: Map.get(authorizer, :changeset)})
    end

    def match?(actor, opts, %{changeset: %{data: resource} = changeset}) do
      opts = if is_list(opts), do: opts, else: []
      requester_attr = Keyword.get(opts, :requester_attribute, :requested_by)
      approver_attr = Keyword.get(opts, :approver_attribute, :approved_by)

      requester_id = Map.get(resource, requester_attr)
      actor_id = actor_id(actor)
      approver_id = Ash.Changeset.get_attribute(changeset, approver_attr)

      not self_approval_allowed?(resource) and
        requester_id not in [nil, ""] and
        (actor_id == requester_id or approver_id == requester_id)
    end

    def match?(_actor, _opts, _context), do: false

    defp actor_id(%{id: id}), do: id
    defp actor_id(%{"id" => id}), do: id
    defp actor_id(_actor), do: nil

    defp self_approval_allowed?(%{reviewer_policy: policy}) when is_map(policy) do
      Map.get(policy, "allow_self_approval") in [true, "true", "1", 1, "yes", "on"] or
        Map.get(policy, :allow_self_approval) in [true, "true", "1", 1, "yes", "on"]
    end

    defp self_approval_allowed?(_resource), do: false
  end

  defmodule ActorHasPermission do
    @moduledoc """
    Check if the actor has a specific RBAC permission key.

    ## Options

      * `:permission` - Permission key string (e.g., \"devices.delete\")
    """
    use SimpleCheck

    alias ServiceRadar.Identity.RBAC

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      permission = Keyword.get(opts, :permission, "unknown")
      "actor has permission #{permission}"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    # Ash may call match?/3 with the authorizer as the 2nd arg and the opts as the 3rd arg.
    def match?(actor, %Authorizer{}, opts) when is_list(opts) do
      match?(actor, opts, %{})
    end

    def match?(actor, opts, _context) do
      opts = if is_list(opts), do: opts, else: []
      permission = Keyword.get(opts, :permission)

      if is_binary(permission) do
        # Fast path: if actor map already has a MapSet of permissions, check directly
        case actor do
          %{permissions: %MapSet{} = perms} ->
            ServiceRadar.Identity.RBAC.Catalog.holds?(perms, permission)

          _ ->
            RBAC.has_permission?(actor, permission)
        end
      else
        false
      end
    end
  end

  defmodule ActorIsNil do
    @moduledoc """
    Check if the actor is missing (used for internal/system-triggered actions).
    """
    use SimpleCheck

    @impl true
    def describe(_opts), do: "actor is nil"

    @impl true
    def match?(nil, _opts, _context), do: true
    def match?(_, _opts, _context), do: false
  end
end
