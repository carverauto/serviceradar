defmodule ServiceRadarWebNG.Authorization.PermissionsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Authorization

  test "admin can manage auth and user resources" do
    auth = Authorization.can(%User{role: :admin})

    assert Authorization.read?(auth, User)
    assert Authorization.update?(auth, User)

    assert Authorization.read?(auth, AuthorizationSettings)
    assert Authorization.update?(auth, AuthorizationSettings)

    assert Authorization.read?(auth, AuthSettings)
    assert Authorization.update?(auth, AuthSettings)
  end

  test "non-admin has no access" do
    auth = Authorization.can(%User{role: :viewer})

    refute Authorization.read?(auth, User)
    refute Authorization.read?(auth, AuthorizationSettings)
    refute Authorization.read?(auth, AuthSettings)
  end
end
