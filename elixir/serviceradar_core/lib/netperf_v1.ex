defmodule Netperf.V1 do
  @moduledoc false

  # Boundary shell for the generated netperf v1 protobuf modules (Netperf.V1.*),
  # mirroring the other proto boundary shells so the generated structs are
  # classified into a boundary and `mix compile` does not warn that they are
  # "not included in any boundary".
  use Boundary,
    top_level?: true,
    exports: :all
end
