defmodule ServiceRadarWebNG.TestSupport.PropertyOpts do
  @moduledoc false

  def max_runs(tag \\ nil) do
    default =
      case tag do
        :slow_property -> 200
        _ -> 50
      end

    "PROPERTY_MAX_RUNS"
    |> System.get_env(Integer.to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end
end
