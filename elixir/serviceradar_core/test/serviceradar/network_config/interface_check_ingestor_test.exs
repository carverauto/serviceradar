defmodule ServiceRadar.NetworkConfig.InterfaceCheckIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.InterfaceCheckIngestor

  @known "sr:00000000-0000-4000-8000-000000000001"
  @unknown "sr:00000000-0000-4000-8000-000000000009"

  defmodule FakeStore do
    @moduledoc false
    def fetch(uid, _actor) do
      send(self(), {:fetch, uid})

      if uid == "sr:00000000-0000-4000-8000-000000000001",
        do: {:ok, %{uid: uid}},
        else: :not_found
    end

    def merge(device, patch, _actor) do
      send(self(), {:merge, device.uid, patch})
      :ok
    end
  end

  defp payload(verdicts) do
    %{
      "status" => "OK",
      "details" =>
        Jason.encode!(%{
          "schema" => "serviceradar.interface_config_check.v1",
          "source" => "opentext-nom",
          "verdicts" => verdicts
        })
    }
  end

  defp verdict(uid, check, status, extra \\ %{}) do
    Map.merge(
      %{
        "device_uid" => uid,
        "check" => check,
        "status" => status,
        "checked_at" => "2026-09-24T00:00:00Z",
        "switch" => "switch01.example.com",
        "interface" => "GigabitEthernet1/0/7"
      },
      extra
    )
  end

  test "claims only interface config check results" do
    assert InterfaceCheckIngestor.supports?(payload([]))
    refute InterfaceCheckIngestor.supports?(%{"details" => Jason.encode!(%{"schema" => "other"})})
    refute InterfaceCheckIngestor.supports?(%{"status" => "OK"})
  end

  test "records each check as a queryable status key plus a detail key" do
    result =
      payload([
        verdict(@known, "nac", "non_compliant", %{
          "missing" => ["authentication port-control auto"]
        }),
        verdict(@known, "desc_foobar", "compliant")
      ])

    assert :ok = InterfaceCheckIngestor.ingest(result, %{}, device_store: FakeStore)
    assert_received {:merge, @known, patch}

    assert patch["config_check_nac"] == "non_compliant"
    assert patch["config_check_nac_detail"]["missing"] == ["authentication port-control auto"]
    assert patch["config_check_nac_detail"]["interface"] == "GigabitEthernet1/0/7"
    assert patch["config_check_desc_foobar"] == "compliant"
    refute Map.has_key?(patch["config_check_desc_foobar_detail"], "missing")
    assert patch |> Map.keys() |> Enum.all?(&String.starts_with?(&1, "config_check_"))
  end

  test "skips devices that do not exist instead of creating them" do
    assert :ok =
             InterfaceCheckIngestor.ingest(payload([verdict(@unknown, "nac", "unknown")]), %{},
               device_store: FakeStore
             )

    assert_received {:fetch, @unknown}
    refute_received {:merge, _, _}
  end

  test "drops malformed verdicts and never writes outside config_check keys" do
    result =
      payload([
        verdict(@known, "Bad Name", "compliant"),
        verdict(@known, "nac", "maybe"),
        verdict("", "nac", "compliant"),
        %{"device_uid" => @known, "check" => "nac"},
        verdict(@known, "ok_check", "unknown", %{"reason" => "configlet_not_found"})
      ])

    assert :ok = InterfaceCheckIngestor.ingest(result, %{}, device_store: FakeStore)
    assert_received {:merge, @known, patch}

    assert patch |> Map.keys() |> Enum.sort() == [
             "config_check_ok_check",
             "config_check_ok_check_detail"
           ]

    assert patch["config_check_ok_check_detail"]["reason"] == "configlet_not_found"
  end

  test "rejects a result without a verdict list" do
    assert {:error, :interface_check_invalid_result} =
             InterfaceCheckIngestor.ingest(
               %{
                 "details" =>
                   Jason.encode!(%{"schema" => "serviceradar.interface_config_check.v1"})
               },
               %{},
               device_store: FakeStore
             )
  end
end
