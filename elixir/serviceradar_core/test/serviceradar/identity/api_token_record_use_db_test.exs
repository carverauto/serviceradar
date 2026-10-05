defmodule ServiceRadar.Identity.ApiTokenRecordUseDbTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.ApiToken
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    system = SystemActor.system(:api_token_record_use_db_test)
    suffix = System.unique_integer([:positive])
    password = "SyntheticTokenUser#{suffix}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "token-user-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: system
      )

    {:ok, token} =
      ApiToken
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "usage-#{suffix}",
          user_id: user.id,
          token: "synthetic-token-#{suffix}-0123456789"
        },
        actor: system,
        authorize?: false
      )
      |> Ash.create()

    {:ok, token: token, system: system}
  end

  test "record_use counts one use by default", %{token: token, system: system} do
    assert {:ok, used} = record_use(token, system, %{last_used_ip: "192.0.2.10"})

    assert used.use_count == 1
    assert used.last_used_ip == "192.0.2.10"
    assert %DateTime{} = used.last_used_at
  end

  test "record_use counts every coalesced use in one write", %{token: token, system: system} do
    assert {:ok, used} = record_use(token, system, %{last_used_ip: "192.0.2.11", uses: 3})
    assert used.use_count == 3

    assert {:ok, used} = record_use(used, system, %{uses: 2})
    assert used.use_count == 5
  end

  defp record_use(token, actor, params) do
    token
    |> Ash.Changeset.for_update(:record_use, params)
    |> Ash.update(actor: actor, authorize?: false)
  end
end
