defmodule ServiceRadarWebNG.Accounts do
  @moduledoc """
  The Accounts context.

  Delegates user operations to ServiceRadar.Identity.Users (Ash-based) while
  maintaining token management via Ecto for session handling.
  """

  import Ecto.Query, warn: false
  alias ServiceRadarWebNG.Repo

  alias ServiceRadar.Identity.Users, as: AshUsers
  alias ServiceRadarWebNG.Accounts.{UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    AshUsers.get_by_email(email)
  end

  def get_user_by_email(%Ash.CiString{} = email) do
    get_user_by_email(to_string(email))
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    AshUsers.get_by_email_and_password(email, password)
  end

  def get_user_by_email_and_password(%Ash.CiString{} = email, password) when is_binary(password) do
    get_user_by_email_and_password(to_string(email), password)
  end

  @doc """
  Gets a single user.

  Raises if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (RuntimeError)

  """
  def get_user!(id), do: AshUsers.get!(id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ash.Error{}}

  """
  def register_user(attrs) do
    AshUsers.register(attrs)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  Note: This returns a basic Ecto changeset for form rendering.
  Actual updates go through Ash.
  """
  def change_user_email(user, attrs \\ %{}, _opts \\ []) do
    # Get current email as string for comparison
    current_email = case user do
      %{email: %Ash.CiString{} = email} -> String.downcase(to_string(email))
      %{email: email} when is_binary(email) -> String.downcase(email)
      _ -> nil
    end

    types = %{email: :string}
    {user, types}
    |> Ecto.Changeset.cast(attrs, [:email])
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> Ecto.Changeset.validate_length(:email, max: 160)
    |> validate_email_changed(current_email)
  end

  defp validate_email_changed(changeset, nil), do: changeset
  defp validate_email_changed(changeset, current_email) do
    case Ecto.Changeset.get_change(changeset, :email) do
      nil -> changeset
      new_email when is_binary(new_email) ->
        if String.downcase(new_email) == current_email do
          Ecto.Changeset.add_error(changeset, :email, "did not change")
        else
          changeset
        end
      _ -> changeset
    end
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    # Convert ci_string to string for context matching
    email_str = to_string(user.email)
    context = "change:#{email_str}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, updated_user} <- AshUsers.update_email(user, %{email: email}),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, updated_user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  Note: This returns a basic Ecto changeset for form rendering.
  Actual updates go through Ash.
  """
  def change_user_password(user, attrs \\ %{}, _opts \\ []) do
    types = %{password: :string, password_confirmation: :string, current_password: :string}
    {user, types}
    |> Ecto.Changeset.cast(attrs, [:password, :password_confirmation, :current_password])
    |> Ecto.Changeset.validate_required([:password])
    |> Ecto.Changeset.validate_length(:password, min: 12, max: 72)
    |> Ecto.Changeset.validate_confirmation(:password, message: "does not match password")
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ..., current_password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ash.Error{}}

  """
  def update_user_password(user, attrs) do
    Repo.transact(fn ->
      with {:ok, updated_user} <- AshUsers.update_password(user, attrs) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {updated_user, tokens_to_expire}}
      end
    end)
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      {user_data, inserted_at} ->
        # Re-fetch user from Ash to get proper struct
        case AshUsers.get(user_data.id) do
          {:ok, user} ->
            # Preserve authenticated_at from the token data
            user = %{user | authenticated_at: user_data.authenticated_at}
            {user, inserted_at}

          {:error, _} ->
            nil
        end

      nil ->
        nil
    end
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user_data, _token} <- Repo.one(query) do
      # Re-fetch user from Ash to get proper struct
      case AshUsers.get(user_data.id) do
        {:ok, user} -> user
        {:error, _} -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%{confirmed_at: nil} = user_data, _token} ->
        # Fetch and confirm user via Ash
        case AshUsers.get(user_data.id) do
          {:ok, user} ->
            case AshUsers.confirm(user) do
              {:ok, confirmed_user} ->
                tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)
                Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))
                {:ok, {confirmed_user, tokens_to_expire}}

              {:error, error} ->
                {:error, error}
            end

          {:error, _} ->
            {:error, :not_found}
        end

      {user_data, token_record} ->
        Repo.delete!(token_record)
        # Fetch user from Ash
        case AshUsers.get(user_data.id) do
          {:ok, user} -> {:ok, {user, []}}
          {:error, _} -> {:error, :not_found}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end
end
