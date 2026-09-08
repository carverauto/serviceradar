defmodule ServiceRadar.Automation.Northbound.TargetPayloadContractTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Northbound.TargetPayloadContract

  test "keeps full targets when descriptor does not declare supported fields" do
    targets = [
      %{
        "kind" => "interface",
        "device_uid" => "sr:device-1",
        "interface_uid" => "if-1",
        "if_index" => 17,
        "if_name" => "Gi1/0/17"
      }
    ]

    assert TargetPayloadContract.apply(%{metadata: %{}}, targets) == targets
  end

  test "filters target payloads by per-kind supported field contract" do
    descriptor = %{
      metadata: %{
        "target_fields" => %{
          "interface" => ["device_ip", "if_name", "if_index"]
        }
      }
    }

    targets = [
      %{
        "kind" => "interface",
        "northbound_job_id" => "job-1",
        "callback" => %{"url" => "https://example.invalid/callback"},
        "device_uid" => "sr:device-1",
        "interface_uid" => "if-1",
        "device_ip" => "192.0.2.10",
        "if_index" => 17,
        "if_name" => "Gi1/0/17",
        "if_alias" => "hidden-by-contract"
      }
    ]

    assert [
             %{
               "kind" => "interface",
               "northbound_job_id" => "job-1",
               "callback" => %{"url" => "https://example.invalid/callback"},
               "device_uid" => "sr:device-1",
               "interface_uid" => "if-1",
               "device_ip" => "192.0.2.10",
               "if_index" => 17,
               "if_name" => "Gi1/0/17"
             }
           ] = TargetPayloadContract.apply(descriptor, targets)
  end
end
