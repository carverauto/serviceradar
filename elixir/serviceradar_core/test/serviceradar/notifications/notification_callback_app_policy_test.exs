defmodule ServiceRadar.Notifications.NotificationCallbackAppPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationCallbackApp

  @providers_manage "notifications.providers.manage"
  @alerts_manage "observability.alerts.manage"

  test "secret-bearing actions require both provider and alert management authority" do
    providers_only = actor([@providers_manage])
    alerts_only = actor([@alerts_manage])
    both = actor([@providers_manage, @alerts_manage])

    for action <- [:register, :rotate_secret, :destroy] do
      refute Ash.can?({NotificationCallbackApp, action}, providers_only, maybe_is: false)
      refute Ash.can?({NotificationCallbackApp, action}, alerts_only, maybe_is: false)
      assert Ash.can?({NotificationCallbackApp, action}, both, maybe_is: false)
    end
  end

  test "provider managers may still read the registry and update a label" do
    providers_only = actor([@providers_manage])

    assert Ash.can?({NotificationCallbackApp, :read}, providers_only, maybe_is: false)
    assert Ash.can?({NotificationCallbackApp, :update}, providers_only, maybe_is: false)
  end

  defp actor(permissions) do
    %{
      id: Ash.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new(permissions)
    }
  end
end
