defmodule ServiceRadar.Identity.Validations.PasswordConfirmationMatches do
  @moduledoc """
  Validates that the password confirmation argument matches the password argument.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    password = Ash.Changeset.get_argument(changeset, :password)
    confirmation = Ash.Changeset.get_argument(changeset, :password_confirmation)

    if password == confirmation do
      :ok
    else
      {:error, field: :password_confirmation, message: "does not match password"}
    end
  end
end
