defmodule ServiceRadarWebNGWeb.Plugs.LockoutCheckTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.LockoutCheck

  describe "init/1" do
    test "rejects an empty config" do
      assert_raise ArgumentError, ~r/requires :actor_id_param or :actor_id_assign/, fn ->
        LockoutCheck.init([])
      end
    end

    test "accepts actor_id_param alone" do
      assert %{param: "email", assign: nil} = LockoutCheck.init(actor_id_param: "email")
    end

    test "accepts actor_id_assign alone" do
      assert %{param: nil, assign: :current_user} =
               LockoutCheck.init(actor_id_assign: :current_user)
    end

    test "accepts both with a default assign id field of :id" do
      assert %{param: "email", assign: :current_user, id_field: :id} =
               LockoutCheck.init(actor_id_param: "email", actor_id_assign: :current_user)
    end
  end

  describe "no actor_id" do
    test "passes through when neither the param nor the assign is populated" do
      opts = LockoutCheck.init(actor_id_param: "email")
      conn = Plug.Test.conn(:post, "/auth/sign-in")

      result = LockoutCheck.call(conn, opts)

      refute result.halted
      assert result == conn
    end
  end

  ## End-to-end (allow + halt) paths exercise Lockouts.active_lockout/1
  ## which hits Postgres. Those tests live in the DB-backed integration
  ## suite (see test_helper.exs guard); the unit suite covers the
  ## configuration and short-circuit paths above.
end
