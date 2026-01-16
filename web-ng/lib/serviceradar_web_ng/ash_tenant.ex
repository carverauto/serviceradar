defmodule ServiceRadarWebNG.AshTenant do
  @moduledoc """
  Ash protocol implementations for scope handling.

  This module implements `Ash.Scope.ToOpts` for our Scope struct, allowing
  Ash to automatically extract actor when operations are called with `scope:` option.

  This is a tenant instance UI - each instance serves ONE tenant. The tenant
  context is implicit from the database connection's search_path, so we only
  need to track the authenticated user.

  ## How it works

  When you call an Ash operation like:

      Ash.read(query, scope: scope)

  Ash uses `Ash.Scope.ToOpts` to extract:
  - actor (the user)

  Since tenant is implicit from the PostgreSQL search_path in tenant instance
  deployments, we don't extract tenant from scope.

  ## Usage in LiveViews

  Simply pass the scope to Ash operations:

      Ash.read(query, scope: socket.assigns.current_scope)

  The user is extracted as the actor. Tenant context comes from the DB connection.
  """
end

# Implement Ash.Scope.ToOpts for the Scope struct
# This allows passing `scope: scope` to Ash operations
defimpl Ash.Scope.ToOpts, for: ServiceRadarWebNG.Accounts.Scope do
  @doc """
  Extract the actor (user) from the Scope.
  """
  def get_actor(%{user: user}), do: {:ok, user}

  @doc """
  Extract the tenant from the Scope.

  In a tenant instance UI, the tenant is implicit from the PostgreSQL search_path.
  We return :error to indicate no explicit tenant override is needed.
  """
  def get_tenant(_), do: :error

  @doc """
  Extract shared context from the Scope.

  In a tenant instance UI, no additional context is needed.
  """
  def get_context(_), do: :error

  @doc """
  No tracers configured in scope.
  """
  def get_tracer(_), do: :error

  @doc """
  Authorization is handled by Ash policies, not overridden here.
  """
  def get_authorize?(_), do: :error
end
