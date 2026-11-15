defmodule ServiceRadar.Credentials.NetworkCredentialRuleTargetQueryTest do
  @moduledoc """
  A credential rule covers every device its target query matches: materialization
  reads the whole selection, so a `limit:` in the query would be silently
  ignored. The rule's actions refuse one when the query is written, and leave a
  query stored before that rule alone until it is edited.

  The changesets are built, not submitted: the validation runs while the
  changeset is built, so no database is involved. The atomic path is covered by
  `NetworkCredentialRuleValidationDbTest`.
  """

  use ExUnit.Case, async: true

  alias Ash.Changeset
  alias ServiceRadar.Credentials.NetworkCredentialRule

  test "create and update refuse a target query with limit:" do
    create =
      Changeset.for_create(NetworkCredentialRule, :create, %{
        name: "rule01",
        provider: "snmp",
        auth_method: "community",
        purpose: "snmp_monitoring",
        target_query: "in:devices vendor_name:Example limit:50",
        scope_type: :agent,
        scope_value: "agent-site01-01",
        secret_id: Ash.UUID.generate()
      })

    update =
      Changeset.for_update(stored_rule("in:devices"), :update, %{
        target_query: "in:devices limit:50"
      })

    for changeset <- [create, update] do
      refute changeset.valid?
      assert target_query_error(changeset) =~ "limit:50 cannot be used in a target query"
    end
  end

  test "an update that leaves a stored limit: query alone is not refused" do
    changeset =
      Changeset.for_update(stored_rule("in:devices sort:uid:asc limit:1"), :update, %{
        name: "rule01-renamed"
      })

    assert changeset.valid?, inspect(changeset.errors)
  end

  defp stored_rule(target_query) do
    %NetworkCredentialRule{
      id: Ash.UUID.generate(),
      name: "rule01",
      provider: "snmp",
      auth_method: "community",
      purpose: "snmp_monitoring",
      target_query: target_query,
      scope_type: :agent,
      scope_value: "agent-site01-01",
      secret_id: Ash.UUID.generate(),
      enabled: true,
      priority: 100,
      allowed_ports: [],
      tls_policy: :verify,
      ssh_host_key_policy: :known_hosts,
      metadata: %{}
    }
  end

  defp target_query_error(changeset) do
    changeset.errors
    |> Enum.filter(&(Map.get(&1, :field) == :target_query))
    |> Enum.map_join("; ", &Exception.message/1)
  end
end
