defmodule ServiceRadar.Automation.Northbound.ActionLifecycleTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.CommandResultHandler
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Automation.Northbound.PollWorker
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original_crypto_secret = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      if original_crypto_secret do
        Application.put_env(:serviceradar_core, :crypto_secret, original_crypto_secret)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end
    end)

    actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-lifecycle@serviceradar.local",
      role: :admin
    }

    {:ok, actor: actor, runtime_actor: SystemActor.system(:northbound_action_lifecycle_test)}
  end

  test "target lifecycle records polling state and redacts persisted result payloads", %{
    actor: actor,
    runtime_actor: runtime_actor
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
               actor: runtime_actor
             )

    assert polling.status == :polling
    assert polling.external_correlation_id == "external-job-1"
    assert polling.result["api_token"] == "[REDACTED]"
    assert polling.continuation_state["api_token"] == "secret-token"

    assert DateTime.compare(polling.next_poll_at, DateTime.truncate(next_poll_at, :microsecond)) ==
             :eq

    assert {:ok, %Oban.Job{} = poll_job} = PollWorker.schedule_target(polling, next_poll_at)
    assert poll_job.args == %{"target_id" => polling.id}

    assert {:ok, fetching} =
             ActionInvocationTarget.record_result_fetching(
               polling,
               %{result: %{"message" => "fetching results"}, last_poll_at: DateTime.utc_now()},
               actor: runtime_actor
             )

    assert fetching.status == :result_fetching

    assert {:ok, succeeded} =
             ActionInvocationTarget.record_succeeded(
               fetching,
               %{result: %{"message" => "complete"}},
               actor: runtime_actor
             )

    assert succeeded.status == :succeeded
    assert succeeded.next_poll_at == nil
    assert %DateTime{} = succeeded.completed_at
  end

  test "expired poll target marks target and invocation expired", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
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
               actor: runtime_actor
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

  test "callback handler preserves token-only callback compatibility", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
    {:ok, target} = create_callback_target(actor, :token)

    assert {:ok, :accepted} =
             CommandResultHandler.handle_callback_result(
               target.id,
               %{"status" => "succeeded", "result" => %{"message" => "complete"}},
               actor: runtime_actor,
               token: "callback-token"
             )

    assert {:ok, updated} = ActionInvocationTarget.get_by_id(target.id, actor: actor)
    assert updated.status == :succeeded
    assert updated.result["message"] == "complete"
  end

  test "callback handler accepts valid signed callbacks", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
    {:ok, target} = create_callback_target(actor, :hmac_required)
    raw_body = ~s({"status":"succeeded","result":{"message":"signed complete"}})
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    signature = callback_signature("callback-hmac-secret", timestamp, raw_body)

    assert {:ok, :accepted} =
             CommandResultHandler.handle_callback_result(
               target.id,
               %{"status" => "succeeded", "result" => %{"message" => "signed complete"}},
               actor: runtime_actor,
               token: "callback-token",
               raw_body: raw_body,
               headers: %{
                 "x-serviceradar-callback-timestamp" => timestamp,
                 "x-serviceradar-callback-signature" => signature
               }
             )

    assert {:ok, updated} = ActionInvocationTarget.get_by_id(target.id, actor: actor)
    assert updated.status == :succeeded
    assert updated.result["message"] == "signed complete"
  end

  test "callback handler rejects invalid signed callbacks", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
    {:ok, target} = create_callback_target(actor, :hmac_required)
    raw_body = ~s({"status":"succeeded"})
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()

    assert {:error, :invalid_callback_signature} =
             CommandResultHandler.handle_callback_result(
               target.id,
               %{"status" => "succeeded"},
               actor: runtime_actor,
               token: "callback-token",
               raw_body: raw_body,
               headers: %{
                 "x-serviceradar-callback-timestamp" => timestamp,
                 "x-serviceradar-callback-signature" => "sha256=bad"
               }
             )

    assert {:ok, updated} = ActionInvocationTarget.get_by_id(target.id, actor: actor)
    assert updated.status == :running
  end

  test "callback handler rejects stale signed callbacks", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
    {:ok, target} = create_callback_target(actor, :hmac_required)
    raw_body = ~s({"status":"succeeded"})

    timestamp =
      DateTime.utc_now()
      |> DateTime.add(-600, :second)
      |> DateTime.to_unix()
      |> Integer.to_string()

    signature = callback_signature("callback-hmac-secret", timestamp, raw_body)

    assert {:error, :stale_callback_signature} =
             CommandResultHandler.handle_callback_result(
               target.id,
               %{"status" => "succeeded"},
               actor: runtime_actor,
               token: "callback-token",
               raw_body: raw_body,
               headers: %{
                 "x-serviceradar-callback-timestamp" => timestamp,
                 "x-serviceradar-callback-signature" => signature
               }
             )
  end

  test "callback handler rejects missing signatures in required mode", %{
    actor: actor,
    runtime_actor: runtime_actor
  } do
    {:ok, target} = create_callback_target(actor, :hmac_required)

    assert {:error, :missing_callback_signature} =
             CommandResultHandler.handle_callback_result(
               target.id,
               %{"status" => "succeeded"},
               actor: runtime_actor,
               token: "callback-token",
               raw_body: ~s({"status":"succeeded"}),
               headers: %{}
             )
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

  defp create_callback_target(actor, mode) do
    runtime_actor = SystemActor.system(:northbound_action_lifecycle_test)

    with {:ok, target} <- create_target(actor),
         {:ok, invocation} <- ActionInvocation.get_by_id(target.invocation_id, actor: actor),
         {:ok, _invocation} <- ActionInvocation.record_running(invocation, actor: runtime_actor),
         {:ok, target} <-
           ActionInvocationTarget.record_running(target, %{}, actor: runtime_actor) do
      attrs =
        maybe_put_hmac_secret(
          %{
            callback_token_hash: sha256_hex("callback-token"),
            callback_url: "https://service.example/api/northbound/action-callbacks/#{target.id}",
            callback_auth_mode: mode,
            callback_hmac_algorithm: "hmac-sha256",
            callback_hmac_signature_header: "x-serviceradar-callback-signature",
            callback_hmac_timestamp_header: "x-serviceradar-callback-timestamp",
            callback_hmac_timestamp_tolerance_seconds: 300
          },
          mode
        )

      ActionInvocationTarget.prepare_callback(target, attrs, actor: runtime_actor)
    end
  end

  defp maybe_put_hmac_secret(attrs, mode) when mode in [:hmac_required, :hmac_optional] do
    Map.put(attrs, :callback_hmac_secret_ciphertext, Crypto.encrypt("callback-hmac-secret"))
  end

  defp maybe_put_hmac_secret(attrs, _mode), do: attrs

  defp callback_signature(secret, timestamp, raw_body) do
    digest =
      :hmac
      |> :crypto.mac(:sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  defp sha256_hex(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
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
