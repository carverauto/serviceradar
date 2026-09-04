defmodule ServiceRadar.Identity.Changes.RequirePrivilegeBoundary do
  @moduledoc false

  use Ash.Resource.Validation

  @message "must be called through the privilege mutation boundary"

  @impl true
  def validate(changeset, _opts, _context) do
    if Map.get(changeset.context, :privilege_boundary_owned) == true do
      :ok
    else
      {:error, @message}
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
