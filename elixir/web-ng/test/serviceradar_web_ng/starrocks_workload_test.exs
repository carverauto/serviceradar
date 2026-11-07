defmodule ServiceRadarWebNG.StarRocksWorkloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Workload

  @moduletag :db_free

  # web-ng serves the interactive reads. Its config is what keeps them out of
  # the background group core's pool pins to.
  test "web-ng's warehouse sessions are pinned to the interactive group" do
    assert MySQL.connection_opts([])[:after_connect] ==
             {Workload, :pin_session, ["sr_interactive"]}
  end
end
