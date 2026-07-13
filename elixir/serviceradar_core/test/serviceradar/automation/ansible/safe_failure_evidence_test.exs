defmodule ServiceRadar.Automation.Ansible.SafeFailureEvidenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence

  defmodule SecretFailure do
    @moduledoc false
    defexception [:message]
  end

  test "classifies only bounded structure and never secret-bearing contents" do
    secret = "callback-bearer-must-not-escape"

    values = [
      :dispatch_failed,
      {:error, :database_unavailable},
      {:transport_failed, %{response_body: secret}},
      %SecretFailure{message: secret},
      %{query_params: [secret]}
    ]

    evidence = Enum.map(values, &SafeFailureEvidence.classification/1)

    assert Enum.map(evidence, & &1["code"]) == [
             "dispatch_failed",
             "database_unavailable",
             "transport_failed",
             "internal_error",
             "internal_error"
           ]

    assert Enum.at(evidence, 2)["kind"] == "tagged_tuple"
    assert Enum.at(evidence, 2)["arity"] == 2
    assert Enum.at(evidence, 3)["kind"] == "exception_struct"
    assert Enum.at(evidence, 3)["module"] =~ "SecretFailure"

    refute inspect(evidence) =~ secret

    Enum.each(values, fn value ->
      assert {:ok, digest} = SafeFailureEvidence.digest(value)
      assert digest =~ ~r/\A[0-9a-f]{64}\z/
    end)
  end
end
