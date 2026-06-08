defmodule Serviceradar.Agent.Addon.V1 do
  @moduledoc false

  # Boundary shell for generated add-on v1 protobuf modules
  # (Serviceradar.Agent.Addon.V1.*), matching the netprobe v1 proto boundary.
  use Boundary,
    top_level?: true,
    exports: :all
end
