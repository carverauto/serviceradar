defmodule ServiceRadarWebNG.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `ServiceRadarWebNG.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Each deployment serves a single account. Schema context is implicit from the
  database connection's search_path, so we only need to track the authenticated user.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias ServiceRadar.Identity.User

  defstruct user: nil, permissions: nil

  @type t :: %__MODULE__{
          user: User.t() | map() | nil,
          permissions: term()
        }

  @doc """
  Creates a scope for the given user.

  Returns a scope struct with the user, or nil user if not authenticated.
  The schema context is implicit from the PostgreSQL search_path.
  """
  def for_user(user, opts \\ [])

  def for_user(%User{} = user, opts) do
    permissions = Keyword.get(opts, :permissions)
    %__MODULE__{user: user, permissions: permissions}
  end

  # Also accept map-like users (for backwards compatibility during transition)
  def for_user(%{id: _, email: _} = user, opts) do
    permissions = Keyword.get(opts, :permissions)
    %__MODULE__{user: user, permissions: permissions}
  end

  def for_user(nil, _opts), do: %__MODULE__{user: nil, permissions: nil}

  @doc """
  Returns true if the user has admin role.
  """
  def admin?(%{user: %{role: :admin}}), do: true
  def admin?(_), do: false
end
