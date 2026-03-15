defmodule ServiceRadarWebNG.Accounts do
  @moduledoc """
  The Accounts context.

  Delegates user operations to ServiceRadar.Identity.Users (Ash-based).
  Session management is handled by Guardian JWT tokens.
  """

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Users, as: AshUsers
  alias ServiceRadarWebNG.Accounts.UserNotifier

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
    # Used by unauthenticated flows (login/reset); run as a system actor so
    # Identity policy hardening doesn't break lookups.
    AshUsers.get_by_email(email, actor: SystemActor.system(:accounts))
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
  def get_user_by_email_and_password(email, password) when is_binary(email) and is_binary(password) do
    AshUsers.get_by_email_and_password(email, password, actor: SystemActor.system(:accounts))
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

  ## Settings

  @doc """
  Returns true if the user has recently authenticated.

  For time-based sudo mode, we verify the `sudo_authenticated_at` timestamp
  against the current time.
  """
  def sudo_mode?(user, sudo_at \\ nil, minutes \\ -20)

  def sudo_mode?(%{id: _}, %DateTime{} = sudo_at, minutes) do
    cutoff = DateTime.add(DateTime.utc_now(), minutes, :minute)
    DateTime.compare(sudo_at, cutoff) != :lt
  end

  def sudo_mode?(_, _, _), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  Note: This returns a basic Ecto changeset for form rendering.
  Actual updates go through Ash.
  """
  def change_user_email(user, attrs \\ %{}, _opts \\ []) do
    # Get current email as string for comparison
    current_email =
      case user do
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
      nil ->
        changeset

      new_email when is_binary(new_email) ->
        if String.downcase(new_email) == current_email do
          Ecto.Changeset.add_error(changeset, :email, "did not change")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  @doc """
  Updates the user email directly.

  Note: For email changes that require confirmation, a Guardian token
  can be generated and sent via email for verification.
  """
  def update_user_email(user, new_email) do
    AshUsers.update_email(user, %{email: new_email})
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

  ## Examples

      iex> update_user_password(user, %{password: ..., current_password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ash.Error{}}

  """
  def update_user_password(user, attrs) do
    AshUsers.update_password(user, attrs)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  Uses Guardian tokens for email verification.
  """
  def deliver_user_update_email_instructions(user, _current_email, _update_email_url_fun) do
    # Email change confirmation uses Guardian tokens
    # This function is kept for API compatibility
    UserNotifier.deliver_update_email_instructions(user, "#")
  end
end
