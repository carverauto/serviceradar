defmodule ServiceRadar.Plugins.MapUtilsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.MapUtils

  test "stringify_keys preserves scalar date and time structs as JSON-safe strings" do
    input = %{
      inserted_at: ~N[2026-05-07 05:50:53],
      observed_at: ~U[2026-05-07 05:50:53Z],
      local_date: ~D[2026-05-07],
      local_time: ~T[05:50:53],
      nested: [%{modified_at: ~N[2026-05-07 05:51:00]}]
    }

    assert MapUtils.stringify_keys(input) == %{
             "inserted_at" => "2026-05-07T05:50:53",
             "observed_at" => "2026-05-07T05:50:53Z",
             "local_date" => "2026-05-07",
             "local_time" => "05:50:53",
             "nested" => [%{"modified_at" => "2026-05-07T05:51:00"}]
           }
  end
end
