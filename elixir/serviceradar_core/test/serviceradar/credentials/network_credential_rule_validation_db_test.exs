defmodule ServiceRadar.Credentials.NetworkCredentialRuleValidationDbTest do
  @moduledoc """
  Rule validations must hold on every way the `:update` action runs.

  A single-record update validates while its changeset is built and only then
  upgrades to an atomic statement. A bulk update given a query never builds
  that changeset: it runs each validation's `atomic/3` and nothing else, so a
  validation whose `atomic/3` accepts everything lets any value through.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  require Ash.Query

  @moduletag :integration

  @actor SystemActor.system(:credential_rule_validation_test)
  @stored_query "in:devices"
  # Parses as SRQL tokens, then fails the parser's limit check.
  @invalid_query "in:devices limit:0"
  @fingerprint "sha256:" <> String.duplicate("a1", 32)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  describe "target_query" do
    test "the update action rejects an invalid query and keeps the stored one" do
      rule = rule_fixture()
      input = %{target_query: @invalid_query}

      assert {:error, error} = NetworkCredentialRule.update_rule(rule, input, actor: @actor)

      assert Exception.message(error) =~ "Invalid SRQL query"
      assert stored(rule).target_query == @stored_query
    end

    test "an atomic bulk update rejects an invalid query and keeps the stored one" do
      rule = rule_fixture()

      result = bulk_update(rule, %{target_query: @invalid_query})

      assert result.status == :error
      assert messages(result) =~ "Invalid SRQL query"
      assert stored(rule).target_query == @stored_query
    end
  end

  describe "trust material" do
    test "the update action rejects a malformed fingerprint" do
      rule = rule_fixture()
      input = %{server_cert_fingerprint: "sha256:abc"}

      assert {:error, error} = NetworkCredentialRule.update_rule(rule, input, actor: @actor)

      assert Exception.message(error) =~ "must be sha256:"
      assert stored(rule).server_cert_fingerprint == nil
    end

    test "an atomic bulk update rejects a malformed fingerprint or CA bundle" do
      rule = rule_fixture()

      for {input, message} <- [
            {%{server_cert_fingerprint: "sha256:abc"}, "must be sha256:"},
            {%{ca_bundle_pem: "not a certificate"}, "is not a valid PEM certificate chain"}
          ] do
        result = bulk_update(rule, input)

        assert result.status == :error, inspect(input)
        assert messages(result) =~ message
      end

      persisted = stored(rule)
      assert persisted.server_cert_fingerprint == nil
      assert persisted.ca_bundle_pem == nil
    end

    test "an atomic bulk update cannot add a CA bundle to a rule holding a fingerprint" do
      rule = rule_fixture(%{server_cert_fingerprint: @fingerprint})

      result = bulk_update(rule, %{ca_bundle_pem: ca_bundle_pem()})

      assert result.status == :error
      assert messages(result) =~ "cannot be combined with a CA bundle"

      persisted = stored(rule)
      assert persisted.server_cert_fingerprint == @fingerprint
      assert persisted.ca_bundle_pem == nil
    end
  end

  test "valid updates still run on both paths" do
    rule = rule_fixture()
    query = "in:devices hostname:host01"
    bundle = ca_bundle_pem()

    result = bulk_update(rule, %{target_query: query, ca_bundle_pem: bundle})
    assert result.status == :success, messages(result)

    name = unique_name()
    input = %{name: name}
    assert {:ok, _renamed} = NetworkCredentialRule.update_rule(stored(rule), input, actor: @actor)

    persisted = stored(rule)
    assert persisted.name == name
    assert persisted.target_query == query
    assert String.trim(persisted.ca_bundle_pem) == String.trim(bundle)
  end

  defp bulk_update(rule, input) do
    NetworkCredentialRule
    |> Ash.Query.filter(id == ^rule.id)
    |> Ash.bulk_update(:update, input, actor: @actor, strategy: :atomic, return_errors?: true)
  end

  defp messages(%Ash.BulkResult{errors: errors}) do
    errors
    |> List.wrap()
    |> Enum.map_join("\n", &Exception.message/1)
  end

  defp stored(rule) do
    {:ok, stored} = NetworkCredentialRule.get_by_id(rule.id, actor: @actor)
    stored
  end

  defp rule_fixture(attrs \\ %{}) do
    secret = CredentialIntegrationFixtures.secret!(actor: @actor)

    defaults = %{
      name: unique_name(),
      provider: "example-network",
      auth_method: "api_token",
      purpose: "inventory",
      target_query: @stored_query,
      scope_type: :agent,
      scope_value: "example-agent",
      secret_id: secret.id
    }

    {:ok, rule} = NetworkCredentialRule.create_rule(Map.merge(defaults, attrs), actor: @actor)
    rule
  end

  # A throwaway self-signed CA generated per run, valid from yesterday for a
  # week, so the fixture can neither expire nor come from a deployment.
  defp ca_bundle_pem do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Example Test CA", [])
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp unique_name, do: "example-rule-#{System.unique_integer([:positive])}"
end
