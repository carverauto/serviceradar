defmodule ServiceRadar.Identity.Changes.InitializeTenantInfrastructureTest do
  @moduledoc """
  Tests for the InitializeTenantInfrastructure Ash change.

  Unit tests verify the module structure and basic functionality.
  Integration tests (tagged :integration) verify full infrastructure setup.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.Changes.InitializeTenantInfrastructure

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(InitializeTenantInfrastructure)
    end

    test "module uses Ash.Resource.Change behaviour" do
      # Check module attributes for the behaviour
      behaviours = InitializeTenantInfrastructure.__info__(:attributes)[:behaviour] || []
      assert Ash.Resource.Change in behaviours
    end

    test "defines initialize_tenant function" do
      # Check if the function exists in the module's functions list
      functions = InitializeTenantInfrastructure.__info__(:functions)
      assert {:initialize_tenant, 1} in functions
    end
  end

  describe "documentation" do
    test "module has moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(InitializeTenantInfrastructure)

      assert is_binary(moduledoc)
      assert String.contains?(moduledoc, "tenant")
    end

    test "moduledoc describes NATS account creation" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(InitializeTenantInfrastructure)

      assert String.contains?(moduledoc, "NATS")
    end
  end
end
