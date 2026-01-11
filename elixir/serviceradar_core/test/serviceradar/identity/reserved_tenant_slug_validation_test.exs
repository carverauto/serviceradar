defmodule ServiceRadar.Identity.ReservedTenantSlugValidationTest do
  @moduledoc """
  Tests for reserved platform tenant slug validation.
  """

  use ExUnit.Case, async: true

  alias Ash.Changeset
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Identity.Validations.ReservedTenantSlug

  setup do
    previous = Application.get_env(:serviceradar_core, :platform_tenant_slug)
    Application.put_env(:serviceradar_core, :platform_tenant_slug, "platform")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :platform_tenant_slug)
      else
        Application.put_env(:serviceradar_core, :platform_tenant_slug, previous)
      end
    end)

    :ok
  end

  defp build_changeset(attrs, is_platform_tenant \\ false) do
    Tenant
    |> Changeset.for_create(:create, Map.merge(%{name: "Test Tenant"}, attrs), authorize?: false)
    |> Changeset.force_change_attribute(:is_platform_tenant, is_platform_tenant)
  end

  test "rejects reserved slug for non-platform tenant" do
    changeset = build_changeset(%{slug: "platform"}, false)

    assert {:error, %{field: :slug}} = ReservedTenantSlug.validate(changeset, [], %{})
  end

  test "requires reserved slug for platform tenant" do
    changeset = build_changeset(%{slug: "default"}, true)

    assert {:error, %{field: :slug}} = ReservedTenantSlug.validate(changeset, [], %{})
  end

  test "allows reserved slug for platform tenant" do
    changeset = build_changeset(%{slug: "platform"}, true)

    assert :ok = ReservedTenantSlug.validate(changeset, [], %{})
  end

  test "allows override of reserved slug via config" do
    Application.put_env(:serviceradar_core, :platform_tenant_slug, "default")

    changeset = build_changeset(%{slug: "default"}, true)

    assert :ok = ReservedTenantSlug.validate(changeset, [], %{})
  end
end
