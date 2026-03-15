defmodule ServiceRadarWebNG.AshScope do
  @moduledoc """
  Ash protocol implementations for scope handling.

  This module implements `Ash.Scope.ToOpts` for our Scope struct, allowing
  Ash to automatically extract actor when operations are called with `scope:`.

  The schema context is implicit from the database connection's search_path,
  so the scope only needs to track the authenticated user.

  ## Usage in LiveViews

      Ash.read(query, scope: socket.assigns.current_scope)
  """

  use Boundary,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Accounts],
    exports: :all
end

defimpl Ash.Scope.ToOpts, for: ServiceRadarWebNG.Accounts.Scope do
  @doc """
  Extract the actor (user) from the Scope.
  """
  def get_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    # Permissions are pre-loaded as MapSet in scope — enrich the actor map
    # so ActorHasPermission.match? can do O(1) MapSet.member? directly.
    actor =
      user
      |> Map.take([:id, :email, :role, :role_profile_id])
      |> Map.put(:permissions, permissions)

    {:ok, actor}
  end

  def get_actor(%{user: user}) when not is_nil(user) do
    {:ok, user}
  end

  def get_actor(%{user: user}), do: {:ok, user}

  @doc """
  Return :error to indicate no explicit override is needed.
  """
  def get_tenant(_), do: :error

  @doc """
  No additional context is needed.
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
