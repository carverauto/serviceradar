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
      opts = if is_list(opts), do: opts, else: []
      role = Keyword.get(opts, :role)
      roles = Keyword.get(opts, :roles, [role])
      "actor has role in #{inspect(roles)}"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

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
    use Ash.Policy.SimpleCheck

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
    use Ash.Policy.SimpleCheck

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
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      "actor owns resource (#{attr} matches)"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, opts, %{changeset: %{data: resource}}) do
      opts = if is_list(opts), do: opts, else: []
      attr = Keyword.get(opts, :attribute, :user_id)
      actor_id = Map.get(actor, :id)
      resource_owner = Map.get(resource, attr)

      actor_id != nil && actor_id == resource_owner
    end

    def match?(_actor, _opts, _context), do: false
  end

  defmodule ActorHasPermission do
    @moduledoc """
    Check if the actor has a specific RBAC permission key.

    ## Options

      * `:permission` - Permission key string (e.g., \"devices.delete\")
    """
    use Ash.Policy.SimpleCheck

    alias ServiceRadar.Identity.RBAC

    @impl true
    def describe(opts) do
      opts = if is_list(opts), do: opts, else: []
      permission = Keyword.get(opts, :permission, "unknown")
      "actor has permission #{permission}"
    end

    @impl true
    def match?(nil, _opts, _context), do: false

    def match?(actor, opts, _context) do
      opts = if is_list(opts), do: opts, else: []
      permission = Keyword.get(opts, :permission)

      if is_binary(permission) do
        RBAC.has_permission?(actor, permission)
      else
        false
      end
    end
  end

  defmodule ActorIsNil do
    @moduledoc """
    Check if the actor is missing (used for internal/system-triggered actions).
    """
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_opts), do: "actor is nil"

    @impl true
    def match?(nil, _opts, _context), do: true
    def match?(_, _opts, _context), do: false
  end
end
