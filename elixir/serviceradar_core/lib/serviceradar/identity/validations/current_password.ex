defmodule ServiceRadar.Identity.Validations.CurrentPassword do
  @moduledoc """
  Validates the current password for sensitive account changes.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok,
     %{
       required_message: Keyword.get(opts, :required_message, "is required"),
       no_password_message: Keyword.get(opts, :no_password_message)
     }}
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, opts, _context) do
    current_password = Ash.Changeset.get_argument(changeset, :current_password)
    user = changeset.data

    cond do
      no_password_set?(user) ->
        validate_no_password(current_password, opts.no_password_message)

      blank?(current_password) ->
        {:error, field: :current_password, message: opts.required_message}

      Bcrypt.verify_pass(current_password, user.hashed_password) ->
        :ok

      true ->
        {:error, field: :current_password, message: "is incorrect"}
    end
  end

  defp validate_no_password(_current_password, nil), do: :ok

  defp validate_no_password(current_password, message) do
    if blank?(current_password) do
      :ok
    else
      {:error, field: :current_password, message: message}
    end
  end

  defp no_password_set?(user), do: is_nil(user.hashed_password) or user.hashed_password == ""

  defp blank?(value), do: is_nil(value) or value == ""
end
