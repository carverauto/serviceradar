defmodule ServiceRadarWebNGWeb.Auth.ClaimDiagnosticsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.ClaimDiagnostics

  @moduletag :db_free

  describe "groups_overage?/1" do
    test "detects a groups claim the IdP replaced with a lookup reference" do
      assert ClaimDiagnostics.groups_overage?(%{"_claim_names" => %{"groups" => "src1"}})
      assert ClaimDiagnostics.groups_overage?(%{"hasgroups" => true})
      refute ClaimDiagnostics.groups_overage?(%{"groups" => ["example-admins"]})
    end
  end

  describe "log_entry/2" do
    test "warns when mappings are configured but none matched, naming what the token carried" do
      diagnosis = diagnosis(%{matched: [], role: :viewer}, 3, [{"roles", ["example-readers"]}])

      assert {:warning, message} = ClaimDiagnostics.log_entry(diagnosis, :oidc)
      assert message =~ "matched no role mapping"
      assert message =~ "mapped_role=viewer"
      assert message =~ "mappings_configured=3"
      assert message =~ "roles=[example-readers]"
    end

    test "logs a matched mapping at info" do
      matched = [%{"source" => "groups", "value" => "example-admins", "role" => "admin"}]
      diagnosis = diagnosis(%{matched: matched, role: :admin}, 1, [{"roles", ["example-admins"]}])

      assert {:info, message} = ClaimDiagnostics.log_entry(diagnosis, :oidc)
      assert message =~ "mapped_role=admin"
      assert message =~ "matched=[groups=example-admins]"
    end

    test "with no mappings configured, an empty match is not a warning" do
      assert {:info, message} =
               ClaimDiagnostics.log_entry(diagnosis(%{matched: [], role: :viewer}, 0, []), :oidc)

      assert message =~ "role_claims: none"
    end

    test "caps the number of claim values it logs" do
      groups = Enum.map(1..40, &"example-group-#{&1}")
      diagnosis = diagnosis(%{matched: [], role: :viewer}, 1, [{"groups", groups}])

      {:warning, message} = ClaimDiagnostics.log_entry(diagnosis, :oidc)

      assert message =~ "example-group-25"
      refute message =~ "example-group-26"
    end
  end

  defp diagnosis(resolution, mapping_count, role_claims) do
    %{
      resolution: Map.merge(%{role_profile_ids: [], user_group_ids: []}, resolution),
      mapping_count: mapping_count,
      role_claims: role_claims,
      identity: [],
      groups_overage?: false
    }
  end
end
