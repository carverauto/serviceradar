defmodule ServiceRadar.Camera.RelaySessionAuthorizationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySessionManager

  test "inventory permission alone cannot start a camera pull" do
    assert {:error, :forbidden} =
             RelaySessionManager.request_open(Ecto.UUID.generate(), Ecto.UUID.generate(),
               scope: %{user: %{id: Ecto.UUID.generate(), permissions: ["devices.view"]}}
             )
  end
end
