defmodule Monitoring do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [Netperf.V1],
    exports: :all
end
