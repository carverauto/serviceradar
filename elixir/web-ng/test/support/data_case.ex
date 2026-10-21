defmodule ServiceRadarWebNG.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test, except `sandbox: :unboxed`,
  which commits. Cleanup for that case is the root AGENTS.md
  Logs & Tests rule. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ServiceRadarWebNG.DataCase, async: true`, although
  this option is not recommended for other databases.

  ## Dedicated Deployment Model

  In a single-deployment architecture, the schema is determined by
  PostgreSQL search_path set via CNPG credentials. No dynamic schema handling
  is needed for tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ServiceRadarWebNG.DataCase

      alias ServiceRadarWebNG.Repo
    end
  end

  setup tags do
    ServiceRadarWebNG.DataCase.setup_sandbox(tags)
    ServiceRadarWebNG.DataCase.ensure_test_schema()
    :ok
  end

  @unboxed_key {__MODULE__, :unboxed}

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(%{sandbox: :unboxed}) do
    Sandbox.mode(ServiceRadar.Repo, :auto)
    Process.put(@unboxed_key, true)

    %{rows: [[started_at, last_job_id]]} =
      ServiceRadar.Repo.query!("SELECT now() AT TIME ZONE 'utc', COALESCE(max(id), 0) FROM platform.oban_jobs")

    on_exit(fn ->
      Sandbox.mode(ServiceRadar.Repo, :manual)
    end)

    # Registered after the mode reset so it runs before it, and after the test's own cleanup.
    on_exit(fn -> delete_committed_side_rows!(started_at, last_job_id) end)
  end

  def setup_sandbox(tags) do
    # Use ServiceRadar.Repo directly for sandbox operations (from serviceradar_core)
    pid = Sandbox.start_owner!(ServiceRadar.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  # Rows an unboxed test commits without naming them: outbox and other Oban jobs that Ash
  # after-action hooks enqueue (a later test's `Oban.drain_queue/1` would run them), and the
  # paper-trail version rows of every resource it wrote. Deleting the parent row leaves its
  # versions behind, because they carry no foreign key. Only one unboxed test runs at a time
  # (they are not async), so everything committed in its window is its own.
  defp delete_committed_side_rows!(started_at, last_job_id) do
    ServiceRadar.Repo.query!("DELETE FROM platform.oban_jobs WHERE id > $1", [last_job_id])

    %{rows: version_tables} =
      ServiceRadar.Repo.query!("""
      SELECT table_name
      FROM information_schema.columns
      WHERE table_schema = 'platform'
        AND table_name LIKE '%\\_versions'
        AND column_name = 'version_inserted_at'
      """)

    for [table] <- version_tables do
      ServiceRadar.Repo.query!(
        ~s(DELETE FROM platform."#{table}" WHERE version_inserted_at >= $1),
        [started_at]
      )
    end
  end

  @doc """
  Deletes a user that a fixture created, when the calling test commits (`sandbox: :unboxed`).

  Fixtures create users the caller never sees -- `operator_user_fixture/1` first creates an
  admin when none exists -- so an unboxed caller cannot delete them itself. A leaked user is
  not harmless: the first registered user becomes admin, so one committed user changes the
  role every later test's first `user_fixture/0` gets. Boxed tests roll the row back with
  the sandbox transaction, so nothing is registered for them.

  Call it from the test process (a test body or `setup`). Its API tokens go with it; any
  other row that still references the user is the test's own to delete.
  """
  def delete_on_exit_if_unboxed(%{id: id} = user) do
    if Process.get(@unboxed_key) do
      on_exit(fn ->
        ServiceRadar.Repo.query!("DELETE FROM platform.api_tokens WHERE user_id = $1", [
          Ecto.UUID.dump!(id)
        ])

        ServiceRadar.Repo.query!("DELETE FROM platform.ng_users WHERE id = $1", [Ecto.UUID.dump!(id)])
      end)
    end

    user
  end

  @doc """
  Ensures the test schema is ready for testing.

  In single-deployment architecture, the schema is determined by
  the database connection's search_path (set via CNPG credentials).
  No dynamic schema creation is needed.
  """
  def ensure_test_schema do
    # Schema is determined by DB connection's search_path in single-deployment mode
    :ok
  end

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
