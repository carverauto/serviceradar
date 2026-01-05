defmodule ServiceRadar.Identity.Validations.ReservedTenantSlug do
  @moduledoc """
  Validates that reserved tenant slugs are only used for the platform tenant.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    slug = slug_value(changeset)

    if is_binary(slug) do
      platform_slug = platform_tenant_slug()
      is_platform = Ash.Changeset.get_attribute(changeset, :is_platform_tenant) == true

      cond do
        slug == platform_slug and not is_platform ->
          {:error,
           field: :slug,
           message: "slug is reserved for the platform tenant"}

        is_platform and slug != platform_slug ->
          {:error,
           field: :slug,
           message: "platform tenant must use reserved slug #{platform_slug}"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp slug_value(changeset) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil -> nil
      %Ash.CiString{} = slug -> slug.string
      slug when is_binary(slug) -> slug
      other -> to_string(other)
    end
  end

  defp platform_tenant_slug do
    Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")
  end
end
