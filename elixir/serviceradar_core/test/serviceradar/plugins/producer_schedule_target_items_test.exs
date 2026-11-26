defmodule ServiceRadar.Plugins.ProducerScheduleTargetItemsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ProducerScheduleDispatcher
  alias ServiceRadar.TestSupport.PagedSRQLRunner

  @devices [
    %{
      "uid" => "sr:00000000-0000-4000-8000-000000000001",
      "hostname" => "host01.example.com",
      "switch_port_attachment" => %{
        "switch_hostname" => "switch01.example.com",
        "port" => "gi1/0/7"
      },
      "metadata" => %{"armis_access_switch" => "switch01.example.com:gi1/0/7"}
    },
    %{
      "uid" => "sr:00000000-0000-4000-8000-000000000002",
      "hostname" => "host02.example.com"
    },
    %{"uid" => "sr:00000000-0000-4000-8000-000000000003"}
  ]

  defp schedule(params, target_input) do
    %{contract: %{"target_input" => target_input}, params: params}
  end

  @target_input %{
    "entity" => "devices",
    "query_param" => "target_query",
    "fields_param" => "target_fields",
    "max_items" => 2
  }

  test "schedules without target_input carry no target items" do
    assert {:ok, nil} =
             ProducerScheduleDispatcher.resolve_target_items(%{contract: %{}, params: %{}},
               runner: PagedSRQLRunner.serving(@devices)
             )
  end

  test "resolves the configured query and projects the requested fields" do
    params = %{
      "target_query" => "in:devices switch_port_attachment.switch_hostname:%",
      "target_fields" => ["switch_port_attachment", "metadata.armis_access_switch"]
    }

    assert {:ok, targets} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(params, @target_input),
               runner: PagedSRQLRunner.serving(@devices)
             )

    assert PagedSRQLRunner.queries() == [
             "in:devices switch_port_attachment.switch_hostname:% sort:uid:asc"
           ]

    assert targets["entity"] == "devices"
    assert targets["total"] == 3
    assert targets["truncated"] == true
    assert [first, second] = targets["items"]

    assert first["uid"] == "sr:00000000-0000-4000-8000-000000000001"
    assert first["fields"]["switch_port_attachment"]["port"] == "gi1/0/7"
    assert first["fields"]["metadata.armis_access_switch"] == "switch01.example.com:gi1/0/7"
    refute Map.has_key?(second, "fields")
  end

  # The reported total is the whole match: SRQL answers a request with no limit
  # with 100 rows, so a one-page read reported at most 100 and never flagged
  # the delivered items as truncated.
  test "reports the total of a selection larger than one SRQL page" do
    devices = Enum.map(1..1_200, &%{"uid" => "sr:device:#{&1}"})
    target_input = Map.put(@target_input, "max_items", 500)

    assert {:ok, targets} =
             ProducerScheduleDispatcher.resolve_target_items(
               schedule(%{"target_query" => "in:devices"}, target_input),
               runner: PagedSRQLRunner.serving(devices)
             )

    assert targets["total"] == 1_200
    assert targets["truncated"] == true
    assert length(targets["items"]) == 500
  end

  test "a missing target query is an error, not an empty run" do
    assert {:error, :missing_target_query} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(%{}, @target_input),
               runner: PagedSRQLRunner.serving(@devices)
             )
  end

  test "an invalid projected field is rejected" do
    params = %{"target_query" => "in:devices", "target_fields" => ["metadata"]}

    assert {:error, [message]} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(params, @target_input),
               runner: PagedSRQLRunner.serving(@devices)
             )

    assert message =~ "invalid input field"
  end
end
