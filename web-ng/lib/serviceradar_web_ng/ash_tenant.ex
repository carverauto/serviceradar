defmodule ServiceRadarWebNG.AshTenant do
  @moduledoc """
  Ash protocol implementations for scope handling.

  This module implements `Ash.Scope.ToOpts` for our Scope struct, allowing
  Ash to automatically extract tenant/actor/context when operations are called
  with `scope:` option.

  Note: `Ash.ToTenant` for `ServiceRadar.Identity.Tenant` is already implemented
  in serviceradar_core (see tenant_to_tenant.ex). That implementation handles
  both `:context` (schema-based) and `:attribute` (column-based) strategies.

  ## How it works

  When you call an Ash operation like:

      Ash.read(query, scope: scope)

  Ash uses `Ash.Scope.ToOpts` to extract:
  - actor (the user)
  - tenant (converted via Ash.ToTenant to schema string)
  - context (any shared context)

  ## Usage in LiveViews

  Instead of manually extracting actor and tenant:

      actor = socket.assigns.current_scope.user
      tenant = TenantSchemas.schema_for_tenant(socket.assigns.current_scope.active_tenant)
      Ash.read(query, actor: actor, tenant: tenant)

  You can simply pass the scope:

      Ash.read(query, scope: socket.assigns.current_scope)
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

  Returns the active_tenant, which Ash will then convert to a schema string
  via the Ash.ToTenant protocol.
  """
  def get_tenant(%{active_tenant: nil}), do: :error
  def get_tenant(%{active_tenant: tenant}), do: {:ok, tenant}

  @doc """
  Extract shared context from the Scope.

  We include tenant_memberships in the shared context for use in policies.
  """
  def get_context(%{tenant_memberships: memberships}) do
    {:ok, %{shared: %{tenant_memberships: memberships}}}
  end

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
