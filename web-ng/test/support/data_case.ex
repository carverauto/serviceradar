defmodule ServiceRadarWebNG.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ServiceRadarWebNG.DataCase, async: true`, although
  this option is not recommended for other databases.

  ## Tenant Instance Model

  In a tenant instance, the tenant schema is determined by PostgreSQL search_path
  set via CNPG credentials. For tests, we use the default tenant schema from config.
  """

  use ExUnit.CaseTemplate

  alias ServiceRadar.Cluster.TenantSchemas

  # Default test tenant slug for schema setup
  @test_tenant_slug "test-tenant"

  using do
    quote do
      alias ServiceRadarWebNG.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ServiceRadarWebNG.DataCase
    end
  end

  setup tags do
    ServiceRadarWebNG.DataCase.setup_sandbox(tags)
    ServiceRadarWebNG.DataCase.ensure_test_schema()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Use ServiceRadar.Repo directly for sandbox operations (from serviceradar_core)
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ServiceRadar.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Ensures the test tenant schema exists for isolated testing.
  """
  def ensure_test_schema do
    # In a tenant instance, we just need to ensure the schema exists
    if not TenantSchemas.schema_exists?(@test_tenant_slug) do
      {:ok, _schema} = TenantSchemas.create_schema(@test_tenant_slug)
    end

    :ok
  end

  @doc """
  Returns the test tenant slug for schema operations.
  """
  def test_tenant_slug, do: @test_tenant_slug

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
