defmodule ServiceRadarWebNGWeb.Auth.PasswordResetDeliveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNGWeb.Auth.PasswordResetDelivery

  @moduletag :db_free

  @email "owner@example.com"
  @active_sso %{is_enabled: true, mode: :active_sso}

  test "accepts an eligible local owner under the same policy as the public reset route" do
    test_pid = self()
    user = owner_user(hashed_password: "$2b$local-hash", local_login_enabled: true)

    assert {:ok, :smtp_accepted} =
             PasswordResetDelivery.deliver(@email,
               user_lookup: fn @email -> {:ok, user} end,
               settings_loader: fn -> {:ok, @active_sso} end,
               token_issuer: fn ^user ->
                 send(test_pid, :token_issued)
                 {:ok, "one-hour-token", %{"typ" => "reset"}}
               end,
               reset_url_builder: &"https://workspace.example/auth/password-reset/#{&1}",
               email_submitter: fn ^user, reset_url ->
                 send(test_pid, {:email_submitted, reset_url})
                 {:ok, :accepted}
               end
             )

    assert_receive :token_issued
    assert_receive {:email_submitted, reset_url}
    assert reset_url =~ "one-hour-token"
  end

  test "does not let the private control-plane route reset an SSO-only identity" do
    test_pid = self()
    user = owner_user(hashed_password: nil, local_login_enabled: false)

    assert {:error, :request_rejected} =
             PasswordResetDelivery.deliver(@email,
               user_lookup: fn @email -> {:ok, user} end,
               settings_loader: fn -> {:ok, @active_sso} end,
               token_issuer: fn _user ->
                 send(test_pid, :token_issued)
                 {:ok, "should-not-exist", %{}}
               end,
               email_submitter: fn _user, _reset_url ->
                 send(test_pid, :email_submitted)
                 {:ok, :accepted}
               end
             )

    refute_receive :token_issued
    refute_receive :email_submitted
  end

  test "fails closed when settings cannot be resolved for a non-opted-in account" do
    test_pid = self()
    user = owner_user(hashed_password: "$2b$historical-hash", local_login_enabled: false)

    assert {:error, :request_rejected} =
             PasswordResetDelivery.deliver(@email,
               user_lookup: fn @email -> {:ok, user} end,
               settings_loader: fn -> {:error, :unavailable} end,
               token_issuer: fn _user ->
                 send(test_pid, :token_issued)
                 {:ok, "should-not-exist", %{}}
               end,
               email_submitter: fn _user, _reset_url ->
                 send(test_pid, :email_submitted)
                 {:ok, :accepted}
               end
             )

    refute_receive :token_issued
    refute_receive :email_submitted
  end

  defp owner_user(attrs) do
    struct!(
      User,
      Keyword.merge(
        [
          id: "11111111-1111-1111-1111-111111111111",
          email: @email,
          role: :admin,
          hashed_password: nil,
          local_login_enabled: false
        ],
        attrs
      )
    )
  end
end
