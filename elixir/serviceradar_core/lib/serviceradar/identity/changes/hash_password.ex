defmodule ServiceRadar.Identity.Changes.HashPassword do
  @moduledoc """
  Ash change that hashes the password argument using bcrypt.

  Used in create and update_password actions to securely store passwords.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, %{force?: Keyword.get(opts, :force?, false)}}

  @impl true
  def change(changeset, opts, _context) do
    case Ash.Changeset.get_argument(changeset, :password) do
      nil ->
        changeset

      password when is_binary(password) and byte_size(password) > 0 ->
        hashed = Bcrypt.hash_pwd_salt(password)
        change_hashed_password(changeset, hashed, opts.force?)

      _ ->
        changeset
    end
  end

  defp change_hashed_password(changeset, hashed_password, true) do
    Ash.Changeset.force_change_attribute(changeset, :hashed_password, hashed_password)
  end

  defp change_hashed_password(changeset, hashed_password, false) do
    Ash.Changeset.change_attribute(changeset, :hashed_password, hashed_password)
  end
end
