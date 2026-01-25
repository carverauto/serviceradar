defmodule ServiceRadar.Plugins do
  @moduledoc """
  The Plugins domain manages Wasm plugin packages, import review, and assignments.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Plugins.Plugin
    resource ServiceRadar.Plugins.PluginPackage
    resource ServiceRadar.Plugins.PluginAssignment
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
