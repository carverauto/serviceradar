defmodule ServiceRadar.Automation.Ansible.DispatchMarkerContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract

  test "defines a restricted survey while keeping the broad variable prompt disabled" do
    contract = DispatchMarkerContract.contract()

    assert contract["schema"] == "serviceradar.awx_dispatch_marker_survey/v1"
    assert contract["channel"] == "restricted_awx_survey"
    assert contract["survey_enabled"] == true
    assert contract["ask_variables_on_launch"] == false

    assert Enum.map(contract["fields"], & &1["variable"]) == [
             "serviceradar_dispatch_id",
             "serviceradar_snapshot_digest"
           ]

    assert {:ok, ^contract} =
             DispatchMarkerContract.from_review_metadata(%{
               "dispatch_marker_contract" => contract
             })
  end

  test "rejects broadened, incomplete, and duplicate-key binding contracts" do
    contract = DispatchMarkerContract.contract()

    for invalid <- [
          Map.put(contract, "ask_variables_on_launch", true),
          Map.put(contract, "channel", "extra_vars"),
          Map.delete(contract, "fields"),
          update_in(contract, ["fields"], &tl/1),
          update_in(
            contract,
            ["fields", Access.at(0), "max"],
            fn _value -> 128 end
          )
        ] do
      assert {:error, :binding_dispatch_marker_contract_invalid} =
               DispatchMarkerContract.validate_contract(invalid)
    end

    assert {:error, :binding_dispatch_marker_contract_invalid} =
             contract
             |> Map.put(:schema, contract["schema"])
             |> DispatchMarkerContract.validate_contract()
  end

  test "accepts only exact marker survey semantics with no default" do
    dispatch = %{
      "variable" => "serviceradar_dispatch_id",
      "question_name" => "ServiceRadar dispatch ID",
      "question_description" => "Injected by ServiceRadar",
      "type" => "text",
      "required" => true,
      "choices" => "",
      "min" => 36,
      "max" => 36,
      "default" => ""
    }

    snapshot = %{
      "variable" => "serviceradar_snapshot_digest",
      "question_name" => "ServiceRadar snapshot digest",
      "type" => "text",
      "required" => true,
      "choices" => "",
      "min" => 64,
      "max" => 64,
      "default" => nil
    }

    assert :ok = DispatchMarkerContract.validate_survey_field(dispatch)
    assert :ok = DispatchMarkerContract.validate_survey_field(snapshot)

    assert {:error, :invalid_dispatch_marker_survey} =
             dispatch
             |> Map.put("required", false)
             |> DispatchMarkerContract.validate_survey_field()

    assert {:error, :invalid_dispatch_marker_survey} =
             dispatch
             |> Map.put("default", "operator-controlled")
             |> DispatchMarkerContract.validate_survey_field()

    assert {:error, :invalid_dispatch_marker_survey} =
             dispatch
             |> Map.put("variable", "ServiceRadar_Dispatch_ID")
             |> DispatchMarkerContract.validate_survey_field()

    assert :not_marker =
             DispatchMarkerContract.validate_survey_field(%{"variable" => "package_version"})
  end
end
