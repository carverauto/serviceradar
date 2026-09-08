defmodule Serviceradar.Agent.Discovery.V1 do
  @moduledoc false

  # Boundary shell for generated discovery v1 protobuf modules
  # (Serviceradar.Agent.Discovery.V1.*), matching the add-on and netprobe v1
  # proto boundaries.
  use Boundary,
    top_level?: true,
    exports: :all
end
