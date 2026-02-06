defmodule ServiceRadar.Identity.Validations.PermissionKeys do
  @moduledoc """
  Validates that permission keys are known to the RBAC catalog.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Identity.RBAC.Catalog

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    permissions =
      Ash.Changeset.get_attribute(changeset, :permissions) ||
        Map.get(changeset.data, :permissions) || []

    case normalize_permissions(permissions) do
      {:ok, normalized} ->
        normalized = Catalog.normalize_permission_keys(normalized)
        validate_permissions(normalized)

      {:error, message} ->
        {:error, field: :permissions, message: message}
    end
  end

  defp normalize_permissions(perms) when is_list(perms) do
    if Enum.all?(perms, &is_binary/1) do
      {:ok, perms}
    else
      {:error, "permissions must be a list of strings"}
    end
  end

  defp normalize_permissions(_), do: {:error, "permissions must be a list of strings"}

  defp validate_permissions(perms) do
    allowed = MapSet.new(Catalog.permission_keys())

    invalid =
      perms
      |> Enum.reject(&MapSet.member?(allowed, &1))

    if invalid == [] do
      :ok
    else
      {:error,
       field: :permissions,
       message: "unknown permission keys: #{Enum.join(invalid, ", ")}"}
    end
  end
end
