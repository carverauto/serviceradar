defmodule ServiceRadarWebNGWeb.DeviceLive.EventsDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EventsData

  @moduletag :db_free

  defmodule RecordingSRQL do
    @moduledoc false

    def query(query, opts) do
      send(Process.get(:events_data_test_pid), {:events_query, query, opts})
      {:ok, %{"results" => [%{"id" => "evt-1", "message" => "synthetic event"}], "pagination" => %{}}}
    end
  end

  test "load_events resolves device identifiers once and bounds the scan by time and limit" do
    Process.put(:events_data_test_pid, self())

    identifiers = ["sr:device-0001", "host01.example.com", "192.0.2.10", "host01.example.com", ""]

    assert {returned_query, {:ok, [%{"id" => "evt-1"}]}} =
             EventsData.load_events(RecordingSRQL, "sr:device-0001", :scope, identifiers: identifiers)

    assert_receive {:events_query, query, opts}

    assert query ==
             ~s|in:events device_uid:["sr:device-0001","host01.example.com","192.0.2.10"] time:last_24h sort:time:desc limit:50|

    assert returned_query == query
    assert opts == %{scope: :scope, limit: 50}
  end

  describe "device_scope_token/2" do
    test "falls back to scalar device_uid when the CNPG lookup is unavailable" do
      token = EventsData.device_scope_token("sr:device-0001")

      assert token == ~s|device_uid:"sr:device-0001"|
      refute token =~ "device_uid:[]"
    end

    test "emits a quoted list when CNPG resolves additional device aliases" do
      token =
        EventsData.device_scope_token("sr:device-0001",
          identifiers: ["host01.example.com", "192.0.2.10"]
        )

      assert token == ~s|device_uid:["sr:device-0001","host01.example.com","192.0.2.10"]|
    end

    test "never emits an empty list filter for a blank device uid" do
      assert EventsData.device_scope_token("") == ~s|device_uid:""|
      refute EventsData.device_scope_token("") =~ "device_uid:["
    end
  end
end
