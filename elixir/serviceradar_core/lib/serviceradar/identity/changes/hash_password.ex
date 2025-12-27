defmodule ServiceRadar.Identity.Changes.HashPassword do
  @moduledoc """
  Ash change that hashes the password argument using bcrypt.

  Used in create and update_password actions to securely store passwords.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :password) do
      nil ->
        changeset

      password when is_binary(password) and byte_size(password) > 0 ->
        hashed = Bcrypt.hash_pwd_salt(password)
        Ash.Changeset.change_attribute(changeset, :hashed_password, hashed)

      _ ->
        changeset
    end
  end
end
