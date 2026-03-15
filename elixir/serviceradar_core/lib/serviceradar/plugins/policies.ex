defmodule ServiceRadar.Plugins.Policies do
  @moduledoc false

  @plugins_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                         permission: "settings.plugins.manage"}

  defmacro manage_action_types(action_types \\ [:create, :update, :destroy]) do
    quote do
      import ServiceRadar.Policies

      system_bypass()

      policy action_type(:read) do
        authorize_if always()
      end

      policy action_type(unquote(action_types)) do
        authorize_if unquote(Macro.escape(@plugins_manage_check))
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
        authorize_if unquote(Macro.escape(@plugins_manage_check))
      end
    end
  end
end
