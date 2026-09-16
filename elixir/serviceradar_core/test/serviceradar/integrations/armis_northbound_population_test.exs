defmodule ServiceRadar.Integrations.ArmisNorthboundPopulationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Integrations.ArmisNorthboundLedger
  alias ServiceRadar.Integrations.ArmisNorthboundPopulation
  alias ServiceRadar.Integrations.ArmisNorthboundRetention
  alias ServiceRadar.Inventory.ArmisSourceSnapshot

  test "successful target retention enforces a safe minimum" do
    assert ArmisNorthboundRetention.retention_days(retention_days: 31) == 31
    assert ArmisNorthboundRetention.retention_days(retention_days: 6) == 30
  end

  describe "collection accounting" do
    test "accepts both population equations" do
      assert :ok = ArmisNorthboundLedger.validate_population(population())
    end

    test "rejects raw-row drift explicitly" do
      population = put_in(population(), [:accounting, :raw_rows], 16)

      assert {:error, :raw_population_equation_mismatch} =
               ArmisNorthboundLedger.validate_population(population)
    end

    test "rejects source-ID disposition drift explicitly" do
      population = Map.put(population(), :withheld_count, 2)

      assert {:error, :disposition_population_equation_mismatch} =
               ArmisNorthboundLedger.validate_population(population)
    end

    test "snapshot activation rejects missing policy exclusions and inconsistent equations" do
      exact = %{
        raw_rows: 15,
        excluded_rows: 1,
        invalid_rows: 0,
        valid_occurrences: 14,
        distinct_source_ids: 12,
        duplicate_occurrences: 2,
        conflicting_duplicate_ids: 0
      }

      assert {:ok, %{excluded_rows: 1}} = ArmisSourceSnapshot.validate_population(exact)

      assert {:error, {:invalid_population_count, :excluded_rows}} =
               exact
               |> Map.delete(:excluded_rows)
               |> ArmisSourceSnapshot.validate_population()

      assert {:error, :population_equation_mismatch} =
               exact
               |> Map.put(:raw_rows, 16)
               |> ArmisSourceSnapshot.validate_population()
    end
  end

  describe "source observation classification" do
    test "eligible requires one matching typed ID and availability" do
      assert %{disposition: :eligible, source_object_id: "101"} =
               classify(observation(), ["101"], true, false)
    end

    test "scoped integration identity must match the source and native ID" do
      for integration_id <- ["101", "armis:source-a:device:101"] do
        observation =
          Map.update!(observation(), :metadata, fn metadata ->
            Map.merge(metadata, %{
              "integration_type" => "armis",
              "integration_id" => integration_id
            })
          end)

        assert %{disposition: :eligible} = classify(observation, ["101"], true, false)
      end

      for integration_id <- [
            "armis:source-b:device:101",
            "armis:source-a:device:202",
            "armis:source-a:guest:101",
            "armis::device:101"
          ] do
        observation =
          Map.update!(observation(), :metadata, fn metadata ->
            Map.merge(metadata, %{
              "integration_type" => "armis",
              "integration_id" => integration_id
            })
          end)

        assert %{disposition: :withheld, reason: "metadata_identifier_disagreement"} =
                 classify(observation, ["101"], true, false)
      end
    end

    test "same canonical UID with multiple distinct Armis IDs is withheld" do
      assert %{disposition: :withheld, reason: "multiple_typed_ids_per_device"} =
               classify(observation(), ["101", "202"], true, false)
    end

    test "conflicting repeats are withheld by the exact source ID" do
      assert %{disposition: :withheld, reason: "conflicting_duplicate_payload"} =
               classify(observation(), ["101"], true, true)
    end

    test "metadata disagreement is not fanned out" do
      observation = put_in(observation(), [:metadata, "armis_device_id"], "202")

      assert %{disposition: :withheld, reason: "metadata_identifier_disagreement"} =
               classify(observation, ["101"], true, false)
    end

    test "source linkage mismatch is withheld" do
      observation =
        put_in(
          observation(),
          [:observation_metadata, "identifier_metadata", "sync_service_id"],
          "source-b"
        )

      assert %{disposition: :withheld, reason: "source_linkage_mismatch"} =
               classify(observation, ["101"], true, false)
    end

    test "missing selected availability is withheld" do
      assert %{disposition: :withheld, reason: "missing_availability"} =
               classify(observation(), ["101"], :missing, false)
    end
  end

  defp classify(observation, typed_ids, availability, conflicting?) do
    ArmisNorthboundPopulation.classify_observation(
      observation,
      typed_ids,
      availability,
      conflicting?
    )
  end

  defp observation do
    %{
      source_object_id: "101",
      device_id: "device-a",
      deleted_at: nil,
      metadata: %{"armis_device_id" => "101", "sync_service_id" => "source-a"},
      observation_metadata: %{
        "identifier_metadata" => %{"sync_service_id" => "source-a"}
      },
      expected_source_instance: "source-a"
    }
  end

  defp population do
    %{
      accounted?: true,
      distinct_source_ids: 12,
      eligible_count: 9,
      withheld_count: 3,
      accounting: %{
        raw_rows: 15,
        excluded_rows: 0,
        invalid_rows: 1,
        valid_occurrences: 14,
        distinct_source_ids: 12,
        duplicate_occurrences: 2
      }
    }
  end
end
