defmodule ServiceRadarWebNGWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ServiceRadarWebNGWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ServiceRadarWebNGWeb.Endpoint

      use ServiceRadarWebNGWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ServiceRadarWebNGWeb.ConnCase
    end
  end

  setup tags do
    ServiceRadarWebNG.DataCase.setup_sandbox(tags)
    ServiceRadarWebNG.DataCase.ensure_test_tenant()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture()
    scope = ServiceRadarWebNG.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  Generates an Ash JWT token and stores it in the session under the :user key,
  matching what AshAuthentication.Phoenix.Controller.store_in_session/2 does.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, _opts \\ []) do
    # Generate an Ash JWT token for the user
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{}, tenant: user.tenant_id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
    |> Plug.Conn.put_session("tenant", user.tenant_id)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  @doc """
  Setup helper that registers and logs in users with API bearer token authentication.

  Use this for testing API endpoints that require `:api_key_auth` pipeline.

      setup :register_and_log_in_api_user

  It stores an updated connection (with Authorization header) and a registered user
  in the test context.
  """
  def register_and_log_in_api_user(%{conn: conn} = context) do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture()
    scope = ServiceRadarWebNG.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_api_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn` using API bearer token authentication.

  This sets the `Authorization: Bearer <token>` header for API routes
  that use the `:api_key_auth` pipeline.

  It returns an updated `conn`.
  """
  def log_in_api_user(conn, user, _opts \\ []) do
    # Generate an Ash JWT token for the user
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{}, tenant: user.tenant_id)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end
end
