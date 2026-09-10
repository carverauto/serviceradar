defmodule ServiceRadar.Credentials.NetworkCredentialRuleLifecycleDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @actor SystemActor.system(:credential_rule_lifecycle_test)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "disabled rules cannot issue new grants and live grants prevent deletion" do
    rule = rule_fixture()
    assert {:ok, grant} = issue(rule)
    disabled = disable(rule)

    assert {:error, issue_error} = issue(disabled)
    assert Exception.message(issue_error) =~ "credential_rule_disabled"
    assert {:error, delete_error} = NetworkCredentialRule.destroy_rule(disabled, actor: @actor)
    assert Exception.message(delete_error) =~ "credential_rule_in_use"

    assert {:ok, _} = CredentialBrokerGrant.consume(grant, actor: @actor)
    assert :ok = NetworkCredentialRule.destroy_rule(disabled, actor: @actor)
    assert {:ok, retained} = CredentialBrokerGrant.get_by_id(grant.id, actor: @actor)
    assert retained.credential_rule_id == rule.id
    assert retained.status == :consumed

    assert %{rows: [[count]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.network_credential_rule_versions WHERE version_source_id = ($1::text)::uuid AND version_action_type = 'destroy'",
               [rule.id]
             )

    assert count == 1
  end

  test "enabled rules, changed secret references, and missing rules fail closed" do
    rule = rule_fixture()
    assert {:error, enabled_error} = NetworkCredentialRule.destroy_rule(rule, actor: @actor)
    assert Exception.message(enabled_error) =~ "credential_rule_must_be_disabled"

    other_secret = CredentialIntegrationFixtures.secret!()
    assert {:error, changed_error} = issue(%{rule | secret_id: other_secret.id})
    assert Exception.message(changed_error) =~ "credential_rule_secret_changed"

    assert :ok = rule |> disable() |> NetworkCredentialRule.destroy_rule(actor: @actor)
    assert {:error, missing_error} = issue(rule)
    assert Exception.message(missing_error) =~ "credential_rule_unavailable"
  end

  @tag sandbox: :unboxed
  test "an in-flight grant serializes with disable and delete on another connection" do
    rule = rule_fixture()
    parent = self()

    issuer =
      Task.async(fn ->
        CredentialBrokerGrant
        |> Ash.Changeset.for_create(:issue, grant_attrs(rule), actor: @actor)
        |> Ash.Changeset.after_action(fn _changeset, grant ->
          send(parent, :grant_rule_lock_held)

          receive do
            :finish_grant -> {:ok, grant}
          after
            10_000 -> raise "timed out waiting to finish synthetic grant"
          end
        end)
        |> Ash.create(actor: @actor)
      end)

    try do
      assert_receive :grant_rule_lock_held, 5_000

      deleter =
        Task.async(fn ->
          disabled = disable(rule)
          send(parent, :rule_disabled)
          NetworkCredentialRule.destroy_rule(disabled, actor: @actor)
        end)

      try do
        refute_receive :rule_disabled, 250
        send(issuer.pid, :finish_grant)
        assert {:ok, grant} = Task.await(issuer, 5_000)
        assert {:error, error} = Task.await(deleter, 5_000)
        assert Exception.message(error) =~ "credential_rule_in_use"
        assert {:ok, retained} = NetworkCredentialRule.get_by_id(rule.id, actor: @actor)
        refute retained.enabled
        assert {:ok, _} = CredentialBrokerGrant.get_by_id(grant.id, actor: @actor)
      after
        Task.shutdown(deleter, :brutal_kill)
      end
    after
      send(issuer.pid, :finish_grant)
      Task.shutdown(issuer, :brutal_kill)
      cleanup_fixture(rule)
    end
  end

  defp rule_fixture do
    secret = CredentialIntegrationFixtures.secret!()

    {:ok, rule} =
      NetworkCredentialRule.create_rule(
        %{
          name: "example-rule-#{System.unique_integer([:positive])}",
          provider: "example-network",
          auth_method: "api_token",
          purpose: "inventory",
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: "example-agent",
          secret_id: secret.id
        },
        actor: @actor
      )

    rule
  end

  defp grant_attrs(rule) do
    CredentialBrokerGrant.issue_attrs(%{
      secret_id: rule.secret_id,
      credential_rule_id: rule.id,
      grant_type: "synthetic_inventory_token",
      consumer_kind: :test,
      consumer_id: "example-consumer",
      purpose: "inventory",
      ttl_seconds: 300
    })
  end

  defp issue(rule), do: CredentialBrokerGrant.issue_grant(grant_attrs(rule), actor: @actor)

  defp disable(rule) do
    rule |> Ash.Changeset.for_update(:disable, %{}, actor: @actor) |> Ash.update!(actor: @actor)
  end

  defp cleanup_fixture(rule) do
    # The multi-connection case commits its invented rows. Remove only this
    # test's UUIDs after both children have stopped; ordinary cases roll back.
    Repo.query!(
      "DELETE FROM platform.credential_broker_grants WHERE credential_rule_id = ($1::text)::uuid",
      [rule.id]
    )

    Repo.query!(
      "DELETE FROM platform.network_credential_rule_versions WHERE version_source_id = ($1::text)::uuid",
      [
        rule.id
      ]
    )

    Repo.query!("DELETE FROM platform.network_credential_rules WHERE id = ($1::text)::uuid", [
      rule.id
    ])

    Repo.query!(
      "DELETE FROM platform.network_credential_secret_versions WHERE version_source_id = ($1::text)::uuid",
      [
        rule.secret_id
      ]
    )

    Repo.query!("DELETE FROM platform.network_credential_secrets WHERE id = ($1::text)::uuid", [
      rule.secret_id
    ])
  end
end
