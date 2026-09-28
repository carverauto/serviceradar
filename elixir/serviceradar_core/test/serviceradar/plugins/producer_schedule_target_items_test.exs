defmodule ServiceRadar.Plugins.ProducerScheduleTargetItemsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ProducerScheduleDispatcher

  defmodule RunnerStub do
    @moduledoc false
    def query(query, _opts) do
      send(self(), {:srql_query, query})

      {:ok,
       [
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
       ]}
    end
  end

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
               runner: RunnerStub
             )
  end

  test "resolves the configured query and projects the requested fields" do
    params = %{
      "target_query" => "in:devices switch_port_attachment.switch_hostname:%",
      "target_fields" => ["switch_port_attachment", "metadata.armis_access_switch"]
    }

    assert {:ok, targets} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(params, @target_input),
               runner: RunnerStub
             )

    assert_received {:srql_query, "in:devices switch_port_attachment.switch_hostname:%"}
    assert targets["entity"] == "devices"
    assert targets["total"] == 3
    assert targets["truncated"] == true
    assert [first, second] = targets["items"]

    assert first["uid"] == "sr:00000000-0000-4000-8000-000000000001"
    assert first["fields"]["switch_port_attachment"]["port"] == "gi1/0/7"
    assert first["fields"]["metadata.armis_access_switch"] == "switch01.example.com:gi1/0/7"
    refute Map.has_key?(second, "fields")
  end

  test "a missing target query is an error, not an empty run" do
    assert {:error, :missing_target_query} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(%{}, @target_input),
               runner: RunnerStub
             )
  end

  test "an invalid projected field is rejected" do
    params = %{"target_query" => "in:devices", "target_fields" => ["metadata"]}

    assert {:error, [message]} =
             ProducerScheduleDispatcher.resolve_target_items(schedule(params, @target_input),
               runner: RunnerStub
             )

    assert message =~ "invalid input field"
  end
end
