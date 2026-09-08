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
    resource ServiceRadar.Plugins.PluginRepository
    resource ServiceRadar.Plugins.PluginAssignment
    resource ServiceRadar.Plugins.PluginAssignmentRecoveryAudit
    resource ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
    resource ServiceRadar.Plugins.PluginTargetPolicy
    resource ServiceRadar.Plugins.AddonPackage
    resource ServiceRadar.Plugins.ProducerSchedule
    resource ServiceRadar.Plugins.AddonProfile
    resource ServiceRadar.Plugins.AddonAssignment
    resource ServiceRadar.Plugins.AddonStatus
    resource ServiceRadar.Plugins.AddonRollout
    resource ServiceRadar.Plugins.AddonRolloutTarget
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
