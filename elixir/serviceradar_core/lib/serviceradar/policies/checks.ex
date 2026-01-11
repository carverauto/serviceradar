defmodule ServiceRadar.Policies.Checks do
  @moduledoc """
  Reusable Ash policy checks for ServiceRadar authorization.

  These checks can be used in policy definitions:

      policies do
        policy action_type(:read) do
          authorize_if ServiceRadar.Policies.Checks.ActorHasRole, role: :admin
        end
      end
  """

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
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(opts) do
      role = Keyword.get(opts, :role)
      roles = Keyword.get(opts, :roles, [role])
      "actor has role in #{inspect(roles)}"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, opts, _context) do
      role = Keyword.get(opts, :role)
      roles = Keyword.get(opts, :roles, if(role, do: [role], else: []))

      actor_role = get_role(actor)
      actor_role in roles
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorIsSuperAdmin do
    @moduledoc """
    Check if the actor is a super admin.
    Super admins bypass tenant restrictions.
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_opts), do: "actor is super admin"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, _context) do
      get_role(actor) == :super_admin
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorIsAdmin do
    @moduledoc """
    Check if the actor is an admin (or super admin).
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_opts), do: "actor is admin or super admin"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, _context) do
      get_role(actor) in [:admin, :super_admin]
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule ActorIsOperator do
    @moduledoc """
    Check if the actor is an operator (or higher).
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_opts), do: "actor is operator, admin, or super admin"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, _context) do
      get_role(actor) in [:operator, :admin, :super_admin]
    end

    defp get_role(%{role: role}) when is_atom(role), do: role
    defp get_role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)
    defp get_role(_), do: nil
  end

  defmodule TenantMatches do
    @moduledoc """
    Check if the resource belongs to the actor's tenant.
    Used for multi-tenant isolation.

    Expects the resource to have a `tenant_id` attribute and
    the actor to have a `tenant_id` attribute.
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_opts), do: "resource belongs to actor's tenant"

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, _opts, %{changeset: %{data: resource}}) do
      actor_tenant = get_tenant_id(actor)
      resource_tenant = get_tenant_id(resource)

      actor_tenant != nil && actor_tenant == resource_tenant
    end

    def match?(actor, _opts, %{query: _query, resource: _resource} = context) do
      # For queries, we can't check specific records, so we rely on filters
      # Return true if actor has a tenant_id (actual filtering done via expr)
      Map.has_key?(context, :actor) && get_tenant_id(actor) != nil
    end

    def match?(_actor, _opts, _context), do: false

    defp get_tenant_id(%{tenant_id: tenant_id}), do: tenant_id
    defp get_tenant_id(_), do: nil
  end

  defmodule ActorOwnsResource do
    @moduledoc """
    Check if the actor owns the resource (user_id matches).

    ## Options

      * `:attribute` - The attribute to check (default: :user_id)
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(opts) do
      attr = Keyword.get(opts, :attribute, :user_id)
      "actor owns resource (#{attr} matches)"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, opts, %{changeset: %{data: resource}}) do
      attr = Keyword.get(opts, :attribute, :user_id)
      actor_id = Map.get(actor, :id)
      resource_owner = Map.get(resource, attr)

      actor_id != nil && actor_id == resource_owner
    end

    def match?(_actor, _opts, _context), do: false
  end
end
