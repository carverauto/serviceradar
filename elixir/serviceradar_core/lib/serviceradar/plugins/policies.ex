defmodule ServiceRadar.Plugins.Policies do
  @moduledoc false

  defmacro manage_action_types(action_types \\ [:create, :update, :destroy]) do
    quote do
      import ServiceRadar.Policies

      system_bypass()

      policy action_type(:read) do
        authorize_if always()
      end

      policy action_type(unquote(action_types)) do
        authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: "settings.plugins.manage"}
      end
    end
  end

  defmacro manage_actions(actions) do
    quote do
      import ServiceRadar.Policies

      system_bypass()

      policy action_type(:read) do
        authorize_if always()
      end

      policy action(unquote(actions)) do
        authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: "settings.plugins.manage"}
      end
    end
  end
end
