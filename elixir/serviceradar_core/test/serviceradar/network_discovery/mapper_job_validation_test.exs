defmodule ServiceRadar.NetworkDiscovery.MapperJobValidationTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.NetworkDiscovery.MapperJob

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "accepts mapper jobs with known agent ids" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: "agent-known"}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-known", agent_id: "agent-known"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert job.agent_id == "agent-known"
  end

  @tag :integration
  test "rejects unknown agent ids" do
    actor = SystemActor.system(:test)

    {:error, %Invalid{errors: errors}} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-bad", agent_id: "missing-agent"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end

  @tag :integration
  test "rejects agent ids outside the selected partition" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register,
        %{uid: "agent-partition", metadata: %{"partition_id" => "lab"}},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:error, %Invalid{errors: errors}} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{name: "job-partition", agent_id: "agent-partition", partition: "default"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end

  @tag :integration
  test "rejects updates to unknown agent ids" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: "agent-existing"}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-update", agent_id: "agent-existing"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:error, %Invalid{errors: errors}} =
      job
      |> Ash.Changeset.for_update(:update, %{agent_id: "missing-agent"}, actor: actor)
      |> Ash.update(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end

  @tag :integration
  test "accepts SNMP credentials and rejects any other credential as the job's SNMP credential" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])

    snmp = credential_fixture("SNMP #{suffix}", "snmp", :snmp, actor)
    legacy_rule_secret = credential_fixture("Rule #{suffix}", "snmp", :opaque, actor)
    api_token = credential_fixture("Token #{suffix}", "example-api", :api_token, actor)

    for secret <- [snmp, legacy_rule_secret] do
      assert {:ok, job} = create_job("job-#{secret.name}", secret.id, actor)
      assert job.snmp_credential_secret_id == secret.id
    end

    assert {:error, %Invalid{errors: errors}} =
             create_job("job-token-#{suffix}", api_token.id, actor)

    assert Enum.any?(errors, &(&1.field == :snmp_credential_secret_id))

    {:ok, job} = create_job("job-unbound-#{suffix}", nil, actor)

    assert {:error, %Invalid{errors: errors}} =
             job
             |> Ash.Changeset.for_update(:update, %{snmp_credential_secret_id: api_token.id},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert Enum.any?(errors, &(&1.field == :snmp_credential_secret_id))
  end

  defp create_job(name, secret_id, actor) do
    MapperJob
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, discovery_mode: :snmp, snmp_credential_secret_id: secret_id},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp credential_fixture(name, provider, kind, actor) do
    NetworkCredentialSecret
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, provider: provider, credential_kind: kind, secret_payload: "example-payload"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
