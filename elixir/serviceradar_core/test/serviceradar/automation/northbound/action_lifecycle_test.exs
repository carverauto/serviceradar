defmodule ServiceRadar.Automation.Northbound.ActionLifecycleTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Automation.Northbound.PollWorker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-lifecycle@serviceradar.local",
      role: :admin
    }

    {:ok, actor: actor}
  end

  test "target lifecycle records polling state and redacts persisted result payloads", %{
    actor: actor
  } do
    {:ok, target} = create_target(actor)
    next_poll_at = DateTime.add(DateTime.utc_now(), 30, :second)
    deadline = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, polling} =
             ActionInvocationTarget.record_deferred(
               target,
               %{
                 result: %{"message" => "queued", "api_token" => "secret-token"},
                 external_correlation_id: "external-job-1",
                 continuation_state: %{
                   "external_task_id" => "external-job-1",
                   "api_token" => "secret-token"
                 },
                 next_poll_at: next_poll_at,
                 poll_deadline_at: deadline
               },
               actor: actor
             )

    assert polling.status == :polling
    assert polling.external_correlation_id == "external-job-1"
    assert polling.result["api_token"] == "[REDACTED]"
    assert polling.continuation_state["api_token"] == "secret-token"

    assert DateTime.compare(polling.next_poll_at, DateTime.truncate(next_poll_at, :microsecond)) ==
             :eq

    assert {:error, :oban_unavailable} = PollWorker.schedule_target(polling, next_poll_at)

    assert {:ok, fetching} =
             ActionInvocationTarget.record_result_fetching(
               polling,
               %{result: %{"message" => "fetching results"}, last_poll_at: DateTime.utc_now()},
               actor: actor
             )

    assert fetching.status == :result_fetching

    assert {:ok, succeeded} =
             ActionInvocationTarget.record_succeeded(
               fetching,
               %{result: %{"message" => "complete"}},
               actor: actor
             )

    assert succeeded.status == :succeeded
    assert succeeded.next_poll_at == nil
    assert %DateTime{} = succeeded.completed_at
  end

  test "expired poll target marks target and invocation expired", %{actor: actor} do
    {:ok, target} = create_target(actor)
    deadline = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {:ok, polling} =
             ActionInvocationTarget.record_deferred(
               target,
               %{
                 result: %{"message" => "queued"},
                 external_correlation_id: "external-job-expired",
                 continuation_state: %{"external_task_id" => "external-job-expired"},
                 next_poll_at: DateTime.add(DateTime.utc_now(), -1, :second),
                 poll_deadline_at: deadline
               },
               actor: actor
             )

    assert :ok = PollWorker.perform(%Oban.Job{args: %{"target_id" => polling.id}})

    assert {:ok, expired_target} = ActionInvocationTarget.get_by_id(polling.id, actor: actor)
    assert expired_target.status == :expired
    assert expired_target.result["status"] == "expired"

    assert {:ok, expired_invocation} =
             ActionInvocation.get_by_id(polling.invocation_id, actor: actor)

    assert expired_invocation.state == :expired
    assert expired_invocation.error_class == "provider_timeout"
  end

  defp create_target(actor) do
    with {:ok, provider} <- create_provider(actor),
         {:ok, descriptor} <- create_descriptor(provider, actor),
         {:ok, device} <- create_device(actor),
         {:ok, invocation} <-
           InvocationService.create_invocation(
             %{
               descriptor_id: descriptor.id,
               targets: [%{kind: :device, device_uid: device.uid}],
               input_values: %{"reason" => "test lifecycle"}
             },
             actor: actor
           ) do
      {:ok, hd(invocation.targets)}
    end
  end

  defp create_provider(actor) do
    source_ref = "test:#{System.unique_integer([:positive])}"

    with {:ok, provider} <-
           ActionProvider
           |> Ash.Changeset.for_create(
             :create,
             %{
               name: "Lifecycle Provider",
               provider_type: :native,
               source_ref: source_ref,
               approved_capabilities: [],
               credential_requirements: %{},
               metadata: %{}
             },
             actor: actor
           )
           |> Ash.create(actor: actor, domain: Northbound) do
      provider
      |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
      |> Ash.update(actor: actor, domain: Northbound)
    end
  end

  defp create_descriptor(provider, actor) do
    ActionDescriptor
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        provider_id: provider.id,
        action_id: "test.lifecycle",
        version: "1.0.0",
        label: "Lifecycle Test",
        scopes: ["device"],
        required_context: ["device.ip"],
        input_schema: %{},
        safety_classification: :standard,
        requires_confirmation: false,
        timeout_seconds: 60,
        credential_requirements: %{},
        result_schema_version: "serviceradar.northbound_action_result.v1",
        descriptor_hash: "test-lifecycle",
        enabled: true,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor, domain: Northbound)
  end

  defp create_device(actor) do
    uid = "sr:lifecycle-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        name: "lifecycle-device",
        hostname: "lifecycle-device",
        ip: "192.0.2.30",
        type_id: 0,
        created_time: now,
        modified_time: now,
        discovery_sources: ["test"],
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor, domain: ServiceRadar.Inventory)
  end
end
