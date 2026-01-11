defmodule ServiceRadar.Identity.Validations.UniquePlatformTenant do
  @moduledoc """
  Validates that only one tenant can be marked as the platform tenant.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context) do
    # This validation cannot be done atomically - it requires a database query
    :not_atomic
  end

  @impl true
  def validate(changeset, _opts, _context) do
    # Only validate when is_platform_tenant is being changed to true
    if Ash.Changeset.changing_attribute?(changeset, :is_platform_tenant) do
      case Ash.Changeset.get_attribute(changeset, :is_platform_tenant) do
        true ->
          check_for_existing_platform_tenant(changeset)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp check_for_existing_platform_tenant(changeset) do
    current_id = Ash.Changeset.get_attribute(changeset, :id)

    query =
      ServiceRadar.Identity.Tenant
      |> Ash.Query.filter(is_platform_tenant == true)

    query =
      if current_id do
        Ash.Query.filter(query, id != ^current_id)
      else
        query
      end

    case Ash.read(query, authorize?: false) do
      {:ok, []} ->
        :ok

      {:ok, [existing | _]} ->
        {:error,
         field: :is_platform_tenant,
         message: "A platform tenant already exists: #{existing.name}"}

      {:error, _} ->
        :ok
    end
  end
end
