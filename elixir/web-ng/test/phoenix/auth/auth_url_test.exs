defmodule ServiceRadarWebNGWeb.AuthURLTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AuthURL

  test "password reset URL uses the configured canonical endpoint" do
    assert AuthURL.password_reset_url("reset-token") ==
             "http://localhost:4002/auth/password-reset/reset-token"
  end
end
