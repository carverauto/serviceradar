defmodule ServiceRadar.Identity.AssignFirstUserRoleTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Repo.query!("TRUNCATE TABLE platform.ng_users CASCADE")
    {:ok, actor: SystemActor.system(:assign_first_user_role_test)}
  end

  test "concurrent registrations assign admin to exactly one user", %{actor: actor} do
    barrier = make_ref()
    parent = self()

    tasks =
      Enum.map(1..2, fn idx ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            ^barrier -> :ok
          end

          password = "test_password_#{idx}_123!"

          Users.register_with_password(
            %{
              email: "race-#{idx}-#{System.unique_integer([:positive])}@example.com",
              password: password,
              password_confirmation: password
            },
            actor: actor
          )
        end)
      end)

    ready_pids =
      Enum.map(1..2, fn _ ->
        receive do
          {:ready, pid} -> pid
        end
      end)

    Enum.each(ready_pids, &send(&1, barrier))

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, %User{}}, &1))

    admins =
      User
      |> Ash.Query.for_read(:admins, %{}, actor: actor)
      |> Ash.read!(actor: actor)

    users =
      User
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!(actor: actor)

    assert length(admins) == 1
    assert length(users) == 2
  end
end
