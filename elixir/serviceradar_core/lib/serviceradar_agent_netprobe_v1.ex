defmodule Serviceradar.Agent.Netprobe.V1 do
  @moduledoc false

  # Boundary shell for the generated netprobe v1 protobuf modules
  # (Serviceradar.Agent.Netprobe.V1.*), mirroring the Monitoring/Flowpb proto boundary
  # shells so the generated structs are classified into a boundary and `mix compile`
  # does not warn that they are "not included in any boundary".
  use Boundary,
    top_level?: true,
    exports: :all
end
