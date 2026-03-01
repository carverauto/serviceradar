defmodule ServiceRadar.Spatial do
  @moduledoc """
  The Spatial domain handles all 3D mappings, God-View coordinates, 
  and cyber-physical RF telemetry collected by FieldSurvey agents.
  """
  use Ash.Domain

  resources do
    resource ServiceRadar.Spatial.SurveySample
  end
end
