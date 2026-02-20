defmodule ServiceRadarWebNG.TestSupport.PropertyOpts do
  @moduledoc false

  def max_runs(tag \\ nil) do
    default =
      case tag do
        :slow_property -> 200
        _ -> 50
      end

    System.get_env("PROPERTY_MAX_RUNS", Integer.to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end
end
