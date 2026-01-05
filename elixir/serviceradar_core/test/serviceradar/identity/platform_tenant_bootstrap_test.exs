defmodule ServiceRadar.Identity.PlatformTenantBootstrapTest do
  @moduledoc """
  Integration coverage for platform tenant bootstrap.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query
  import Ash.Expr

  alias ServiceRadar.Identity.Tenant

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    :ok
  end

  test "bootstrap creates platform tenant with reserved slug" do
    platform_slug = Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")

    tenant_query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(expr(is_platform_tenant == true))
      |> Ash.Query.select([:id, :slug, :is_platform_tenant])

    assert {:ok, [tenant]} = Ash.read(tenant_query, authorize?: false)
    assert tenant.slug == platform_slug
    assert to_string(tenant.id) != @zero_uuid
  end
end
