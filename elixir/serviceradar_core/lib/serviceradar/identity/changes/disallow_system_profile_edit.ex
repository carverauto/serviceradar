defmodule ServiceRadar.Identity.Changes.DisallowSystemProfileEdit do
  @moduledoc """
  Prevents destructive edits of system role profiles by non-system actors.

  Guardrail: the built-in `admin` profile must remain immutable so admins can't
  accidentally lock themselves out of RBAC management.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    if system_profile?(changeset) and not system_actor?(context) do
      apply_guardrails(changeset)
    else
      changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp apply_guardrails(changeset) do
    case changeset.action && changeset.action.type do
      # Built-in profiles shouldn't be deletable.
      :destroy ->
        Ash.Changeset.add_error(changeset,
          field: :system,
          message: "system profiles cannot be deleted"
        )

      # Only lock the `admin` profile from edits (guardrail against lockout).
      :update ->
        maybe_block_admin_update(changeset)

      _ ->
        changeset
    end
  end

  defp maybe_block_admin_update(changeset) do
    if locked_system_profile?(changeset) do
      Ash.Changeset.add_error(changeset,
        field: :system,
        message: "admin profile is read-only to prevent lockout; clone to customize"
      )
    else
      changeset
    end
  end

  defp system_profile?(changeset) do
    Ash.Changeset.get_attribute(changeset, :system) ||
      Map.get(changeset.data, :system, false)
  end

  defp locked_system_profile?(changeset) do
    system_name =
      Ash.Changeset.get_attribute(changeset, :system_name) ||
        Map.get(changeset.data, :system_name)

    # Only lock `admin` updates; deletes are handled separately in the UI and/or
    # by leaving system profiles non-deletable.
    to_string(system_name || "") == "admin"
  end

  defp system_actor?(%{actor: %{role: :system}}), do: true
  defp system_actor?(_), do: false
end
