defmodule ServiceRadar.Camera do
  @moduledoc """
  Camera inventory domain for edge-routed live streaming.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Camera.Source
    resource ServiceRadar.Camera.StreamProfile
    resource ServiceRadar.Camera.RelaySession
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
