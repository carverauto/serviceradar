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
  """

  use ExUnit.CaseTemplate

  # Default test tenant ID - must match the UUID format
  @test_tenant_id "00000000-0000-0000-0000-000000000099"

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
    ServiceRadarWebNG.DataCase.ensure_test_tenant()
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
  Ensures the test tenant exists in the database.
  Creates it if it doesn't exist.
  """
  def ensure_test_tenant do
    import Ecto.Query

    tenant_id = test_tenant_id()
    {:ok, tenant_uuid} = Ecto.UUID.dump(tenant_id)

    # Check if tenant already exists
    case ServiceRadar.Repo.get_by(ServiceRadar.Identity.Tenant, id: tenant_id) do
      nil ->
        # Create test tenant directly via SQL to avoid Ash authorization
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        ServiceRadar.Repo.insert_all(
          "tenants",
          [
            %{
              id: tenant_uuid,
              name: "Test Tenant",
              slug: "test-tenant",
              status: "active",
              plan: "enterprise",
              max_devices: 1000,
              max_users: 100,
              settings: %{},
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing
        )

      _tenant ->
        :ok
    end
  end

  @doc """
  Returns the test tenant ID.
  """
  def test_tenant_id, do: @test_tenant_id

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
