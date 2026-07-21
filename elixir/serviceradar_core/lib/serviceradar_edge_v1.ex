defmodule Serviceradar.Edge.V1 do
  @moduledoc false

  # Boundary shell for generated edge v1 protobuf modules
  # (Serviceradar.Edge.V1.*), matching the metric/add-on v1 proto boundaries.
  use Boundary,
    top_level?: true,
    exports: :all
end
