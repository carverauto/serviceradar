defmodule ServiceRadar.Identity.Users do
  @moduledoc """
  Ash-based context module for user operations.

  Provides CRUD operations for managing users using the Ash User resource,
  including authentication, registration, and profile updates.

  This module serves as a facade over the Ash User resource, providing a familiar
  API while leveraging Ash's authorization and authentication features.
  """

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Identity.User

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_by_email("foo@example.com")
      %User{}

      iex> get_by_email("unknown@example.com")
      nil

  """
  @spec get_by_email(String.t(), keyword()) :: User.t() | nil
  def get_by_email(email, opts \\ []) when is_binary(email) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, false)

    case User
         |> Ash.Query.for_read(:by_email, %{email: email}, actor: actor, authorize?: authorize?)
         |> Ash.read_one() do
      {:ok, user} -> user
      {:error, _} -> nil
    end
  end

  @doc """
  Gets a user by email and verifies the password.

  Returns the user if the email exists and the password is correct,
  otherwise returns nil.

  ## Examples

      iex> get_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  @spec get_by_email_and_password(String.t(), String.t(), keyword()) :: User.t() | nil
  def get_by_email_and_password(email, password, opts \\ [])
      when is_binary(email) and is_binary(password) do
    user = get_by_email(email, opts)

    if user && valid_password?(user, password) do
      user
    else
      # Perform a dummy password check to prevent timing attacks
      unless user, do: Bcrypt.no_user_verify()
      nil
    end
  end

  @doc """
  Checks if the given password is valid for the user.
  """
  @spec valid_password?(User.t(), String.t()) :: boolean()
  def valid_password?(%User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _), do: false

  @doc """
  Gets a single user by ID.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def get(id, opts \\ []) when is_binary(id) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, false)

    case Ash.get(User, id, actor: actor, authorize?: authorize?) do
      {:ok, user} -> {:ok, user}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Gets a single user by ID, raising if not found.
  """
  @spec get!(String.t(), keyword()) :: User.t()
  def get!(id, opts \\ []) do
    case get(id, opts) do
      {:ok, user} -> user
      {:error, :not_found} -> raise "User not found: #{id}"
    end
  end

  @doc """
  Registers a new user with email only (for magic link registration).

  ## Options

    * `:tenant_id` - Required tenant ID for the user
    * `:role` - User role (default: :viewer)
    * `:display_name` - Optional display name

  """
  @spec register(map(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def register(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, false)

    # Ensure we have a tenant_id - use default tenant if not provided
    attrs = ensure_tenant_id(attrs)

    User
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: authorize?)
    |> Ash.create()
  end

  @doc """
  Registers a new user with password.

  ## Options

    * `:tenant_id` - Required tenant ID for the user
    * `:password` - Required password
    * `:password_confirmation` - Required password confirmation
    * `:role` - User role (default: :viewer)
    * `:display_name` - Optional display name

  """
  @spec register_with_password(map(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def register_with_password(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, false)

    # Ensure we have a tenant_id - use default tenant if not provided
    attrs = ensure_tenant_id(attrs)

    User
    |> Ash.Changeset.for_create(:register_with_password, attrs,
      actor: actor,
      authorize?: authorize?
    )
    |> Ash.create()
  end

  @doc """
  Updates a user's email address.
  """
  @spec update_email(User.t(), map(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def update_email(user, attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor, user)
    authorize? = Keyword.get(opts, :authorize?, false)

    user
    |> Ash.Changeset.for_update(:update_email, attrs, actor: actor, authorize?: authorize?)
    |> Ash.update()
  end

  @doc """
  Updates a user's password.

  Requires the current password for verification (when user already has a password).
  For users without a password (magic link registration), current_password is not required.
  """
  @spec update_password(User.t(), map(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def update_password(user, attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor, user)
    authorize? = Keyword.get(opts, :authorize?, false)

    # Filter to only valid arguments for change_password action
    valid_keys = [
      :password,
      :password_confirmation,
      :current_password,
      "password",
      "password_confirmation",
      "current_password"
    ]

    filtered_attrs = Map.take(attrs, valid_keys)

    user
    |> Ash.Changeset.for_update(:change_password, filtered_attrs,
      actor: actor,
      authorize?: authorize?
    )
    |> Ash.update()
  end

  @doc """
  Updates a user's role.

  Requires admin privileges.
  """
  @spec update_role(User.t(), atom(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def update_role(user, role, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, true)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: role}, actor: actor, authorize?: authorize?)
    |> Ash.update()
  end

  @doc """
  Confirms a user's email address.
  """
  @spec confirm(User.t(), keyword()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def confirm(user, opts \\ []) do
    actor = Keyword.get(opts, :actor, user)
    authorize? = Keyword.get(opts, :authorize?, false)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> Ash.Changeset.for_update(:update, %{}, actor: actor, authorize?: authorize?)
    |> Ash.Changeset.force_change_attribute(:confirmed_at, now)
    |> Ash.update()
  end

  @doc """
  Lists all users, optionally filtered.

  ## Options

    * `:tenant_id` - Filter by tenant
    * `:role` - Filter by role
    * `:limit` - Maximum number of results (default: 100)
    * `:actor` - The actor performing the query

  """
  @spec list(keyword()) :: {:ok, [User.t()]} | {:error, Ash.Error.t()}
  def list(opts \\ []) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, false)
    limit = Keyword.get(opts, :limit, 100)
    tenant_id = Keyword.get(opts, :tenant_id)
    role = Keyword.get(opts, :role)

    User
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: authorize?)
    |> maybe_filter_tenant(tenant_id)
    |> maybe_filter_role(role)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  # Private helpers

  defp ensure_tenant_id(%{tenant_id: _} = attrs), do: attrs
  defp ensure_tenant_id(%{"tenant_id" => _} = attrs), do: attrs

  defp ensure_tenant_id(attrs) do
    # Try to get default tenant from config or create one
    default_tenant_id =
      Application.get_env(
        :serviceradar_core,
        :default_tenant_id,
        "00000000-0000-0000-0000-000000000000"
      )

    Map.put(attrs, :tenant_id, default_tenant_id)
  end

  defp maybe_filter_tenant(query, nil), do: query

  defp maybe_filter_tenant(query, tenant_id) do
    Ash.Query.filter(query, expr(tenant_id == ^tenant_id))
  end

  defp maybe_filter_role(query, nil), do: query

  defp maybe_filter_role(query, role) do
    Ash.Query.filter(query, expr(role == ^role))
  end
end
