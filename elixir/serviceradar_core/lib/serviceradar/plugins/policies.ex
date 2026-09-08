defmodule ServiceRadar.Plugins.Policies do
  @moduledoc false

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @plugins_manage_check {ActorHasPermission, permission: "settings.plugins.manage"}

  # Deliberately its own permission rather than a reuse of the staging check.
  # Staging means "import from a source the platform already trusts"; adding a
  # repository decides what "trusted" means, which is the strictly larger
  # privilege. Folding them together would let anyone who can import a plugin
  # also declare what counts as a verified one.
  @repositories_manage_check {ActorHasPermission, permission: "plugins.repositories.manage"}

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

  defmacro repositories_manage_action_types(action_types \\ [:create, :update, :destroy]) do
    quote do
      import ServiceRadar.Policies

      system_bypass()

      policy action_type(:read) do
        authorize_if always()
      end

      policy action_type(unquote(action_types)) do
        authorize_if unquote(Macro.escape(@repositories_manage_check))
      end
    end
  end
end
