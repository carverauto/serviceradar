defmodule ServiceRadar.Identity.Validations.ReservedTenantSlug do
  @moduledoc """
  Validates that reserved tenant slugs are only used for the platform tenant.
  """

  use Ash.Resource.Validation

  @reserved_slugs ["serviceradar-operator"]

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    slug = slug_value(changeset)

    if is_binary(slug) do
      platform_slug = platform_tenant_slug()
      reserved_slugs = [platform_slug | @reserved_slugs]
      is_platform = platform_flag(changeset)

      cond do
        slug in reserved_slugs and slug != platform_slug ->
          {:error, field: :slug, message: "slug is reserved for internal platform services"}

        slug == platform_slug and not is_platform ->
          {:error, field: :slug, message: "slug is reserved for the platform tenant"}

        is_platform and slug != platform_slug ->
          {:error,
           field: :slug, message: "platform tenant must use reserved slug #{platform_slug}"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp slug_value(changeset) do
    case changeset_slug(changeset) do
      nil -> data_slug(changeset.data)
      slug -> slug
    end
  end

  defp changeset_slug(changeset) do
    changeset
    |> Ash.Changeset.get_attribute(:slug)
    |> normalize_slug()
  end

  defp data_slug(%{slug: slug}) do
    normalize_slug(slug)
  end

  defp data_slug(_data), do: nil

  defp normalize_slug(nil), do: nil
  defp normalize_slug(%Ash.CiString{} = slug), do: slug.string
  defp normalize_slug(slug) when is_binary(slug), do: slug
  defp normalize_slug(other), do: to_string(other)

  defp platform_flag(changeset) do
    case Ash.Changeset.get_attribute(changeset, :is_platform_tenant) do
      flag when is_boolean(flag) -> flag
      _ -> platform_flag_from_data(changeset.data)
    end
  end

  defp platform_flag_from_data(%{is_platform_tenant: flag}) when is_boolean(flag), do: flag

  defp platform_flag_from_data(%{id: id}) when is_binary(id) or is_struct(id) do
    platform_id = Application.get_env(:serviceradar_core, :platform_tenant_id)
    not is_nil(platform_id) and to_string(id) == to_string(platform_id)
  end

  defp platform_flag_from_data(_data), do: false

  defp platform_tenant_slug do
    Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")
  end
end
