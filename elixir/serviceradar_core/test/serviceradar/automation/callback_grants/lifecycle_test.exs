defmodule ServiceRadar.Automation.CallbackGrants.LifecycleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.CallbackGrants.Audit
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.Callbacks.ActionRegistry

  defmodule FakeAuthorizer do
    @moduledoc false
    @behaviour ServiceRadar.Automation.CallbackGrants.Authorizer

    @impl true
    def current_authority(stage, _grant, pid) do
      Agent.get(pid, fn state ->
        send(state.test, {:authorized, stage})
        state.result
      end)
    end
  end

  defmodule FakeCleanup do
    @moduledoc false
    @behaviour ServiceRadar.Automation.CallbackGrants.Cleanup

    @impl true
    def cleanup(grant, mode, pid) do
      Agent.get_and_update(pid, fn state ->
        send(state.test, {:cleanup, mode, grant})
        {state.result, %{state | calls: [{mode, grant} | state.calls]}}
      end)
    end

    @impl true
    def delete_activated(grant, pid) do
      Agent.get_and_update(pid, fn state ->
        send(state.test, {:delete_activated, grant})
        {state.result, %{state | calls: [{:post_activation, grant} | state.calls]}}
      end)
    end
  end

  defmodule FakeStore do
    @moduledoc false
    @behaviour ServiceRadar.Automation.CallbackGrants.Store

    @impl true
    def create_pending(attrs, audit, pid) do
      Agent.get_and_update(pid, fn state ->
        if Map.has_key?(state.grants, attrs.id) do
          {{:error, :duplicate_grant}, state}
        else
          grant = Map.put(attrs, :audit_count, 1)

          {{:ok, grant},
           %{
             state
             | grants: Map.put(state.grants, attrs.id, grant),
               audits: [audit | state.audits]
           }}
        end
      end)
    end

    @impl true
    def fetch(id, pid) do
      Agent.get(pid, fn state ->
        case Map.fetch(state.grants, id) do
          {:ok, grant} -> {:ok, grant}
          :error -> {:error, :grant_not_found}
        end
      end)
    end

    @impl true
    def bind_credential(id, credential_id, authorize, audit, _now, pid) do
      Agent.get_and_update(pid, fn state ->
        case Map.fetch(state.grants, id) do
          {:ok, %{state: :pending, ephemeral_credential_id: nil} = grant} ->
            case authorize.(grant) do
              :ok ->
                bound =
                  grant
                  |> Map.put(:ephemeral_credential_id, credential_id)
                  |> Map.put(:credential_cleanup_state, :pending)

                {{:ok, :bound, bound},
                 %{
                   state
                   | grants: Map.put(state.grants, id, bound),
                     audits: [audit | state.audits]
                 }}

              {:error, _} = error ->
                {error, state}
            end

          {:ok, %{state: :pending, ephemeral_credential_id: ^credential_id} = grant} ->
            case authorize.(grant) do
              :ok -> {{:ok, :existing, grant}, state}
              {:error, _} = error -> {error, state}
            end

          {:ok, %{state: :pending}} ->
            {{:error, :callback_credential_conflict}, state}

          {:ok, grant} ->
            {{:error, {:grant_not_pending, grant.state}}, state}

          :error ->
            {{:error, :grant_not_found}, state}
        end
      end)
    end

    @impl true
    def bind_job(id, binding, authorize, audit, _now, pid) do
      Agent.get_and_update(pid, fn state ->
        case Map.fetch(state.grants, id) do
          {:ok, %{state: :pending, job_binding: nil} = grant} ->
            case authorize.(grant) do
              :ok ->
                bound = Map.put(grant, :job_binding, binding)

                {{:ok, :bound, bound},
                 %{
                   state
                   | grants: Map.put(state.grants, id, bound),
                     audits: [audit | state.audits]
                 }}

              {:error, _} = error ->
                {error, state}
            end

          {:ok, %{state: :pending, job_binding: ^binding} = grant} ->
            case authorize.(grant) do
              :ok -> {{:ok, :existing, grant}, state}
              {:error, _} = error -> {error, state}
            end

          {:ok, %{state: :pending}} ->
            {{:error, :callback_job_conflict}, state}

          {:ok, grant} ->
            {{:error, {:grant_not_pending, grant.state}}, state}

          :error ->
            {{:error, :grant_not_found}, state}
        end
      end)
    end

    @impl true
    def activate(id, binding, authorize, audit, _now, pid) do
      Agent.get_and_update(pid, fn state ->
        with :ok <- forced(state, :activate),
             {:ok, grant} <- Map.fetch(state.grants, id) do
          activate_locked(state, grant, binding, authorize, audit)
        else
          :error -> {{:error, :grant_not_found}, state}
          {:error, _} = error -> {error, state}
        end
      end)
    end

    defp activate_locked(state, %{state: :pending} = grant, binding, authorize, audit) do
      case authorize.(grant) do
        :ok ->
          activated =
            grant
            |> Map.put(:state, :active)
            |> Map.put(:binding_verified, true)
            |> Map.put(:job_binding, binding)

          {{:ok, :activated, activated},
           %{
             state
             | grants: Map.put(state.grants, grant.id, activated),
               audits: [audit | state.audits]
           }}

        {:error, _} = error ->
          {error, state}
      end
    end

    defp activate_locked(
           state,
           %{state: :active, job_binding: binding} = grant,
           binding,
           authorize,
           _audit
         ) do
      case authorize.(grant) do
        :ok -> {{:ok, :existing, grant}, state}
        {:error, _} = error -> {error, state}
      end
    end

    defp activate_locked(state, %{state: :active}, _binding, _authorize, _audit),
      do: {{:error, :job_binding_conflict}, state}

    defp activate_locked(state, grant, _binding, _authorize, _audit),
      do: {{:error, {:grant_not_pending, grant.state}}, state}

    @impl true
    def consume_once(id, attrs, response, authorize, audit, _now, pid) do
      Agent.get_and_update(pid, fn state ->
        with :ok <- forced(state, :consume),
             {:ok, grant} <- Map.fetch(state.grants, id),
             true <-
               grant.state in [:active, :consumed] ||
                 {:error, {:grant_not_active, grant.state}},
             :ok <- authorize.(grant) do
          consume_locked(state, grant, attrs, response, audit)
        else
          :error -> {{:error, :grant_not_found}, state}
          false -> {{:error, :grant_not_active}, state}
          {:error, _} = error -> {error, state}
        end
      end)
    end

    defp consume_locked(state, grant, attrs, response, audit) do
      case Map.get(state.uses, grant.id) do
        nil when grant.state == :active and grant.budget_remaining == 1 ->
          use = Map.put(attrs, :response, response)

          consumed =
            grant
            |> Map.put(:state, :consumed)
            |> Map.put(:budget_remaining, 0)

          {{:ok, :committed, response, consumed},
           %{
             state
             | grants: Map.put(state.grants, grant.id, consumed),
               uses: Map.put(state.uses, grant.id, use),
               audits: [audit | state.audits]
           }}

        %{idempotency_key_verifier: key, request_digest: digest, response: ^response}
        when key == attrs.idempotency_key_verifier and digest == attrs.request_digest ->
          case forced(state, :replay) do
            :ok ->
              replay_audit = Map.put(audit, :event, "callback_replay")

              {{:ok, :replay, response, grant}, %{state | audits: [replay_audit | state.audits]}}

            {:error, _} = error ->
              {error, state}
          end

        %{idempotency_key_verifier: key} when key == attrs.idempotency_key_verifier ->
          {{:error, :idempotency_payload_conflict}, state}

        _existing ->
          {{:error, :success_budget_consumed}, state}
      end
    end

    @impl true
    def transition_terminal(id, terminal, reason, audit, _now, pid) do
      Agent.get_and_update(pid, fn state ->
        case Map.fetch(state.grants, id) do
          {:ok, grant} ->
            grant = grant |> Map.put(:state, terminal) |> Map.put(:terminal_reason, reason)

            {{:ok, grant},
             %{
               state
               | grants: Map.put(state.grants, id, grant),
                 audits: [audit | state.audits]
             }}

          :error ->
            {{:error, :grant_not_found}, state}
        end
      end)
    end

    @impl true
    def record_cleanup(id, attrs, audit, pid) do
      Agent.update(pid, fn state ->
        %{
          state
          | cleanups: Map.put(state.cleanups, id, attrs),
            audits: [audit | state.audits]
        }
      end)
    end

    @impl true
    def record_audit(audit, pid) do
      Agent.update(pid, &%{&1 | audits: [audit | &1.audits]})
    end

    defp forced(%{force: %{activate: nil}}, :activate), do: :ok
    defp forced(%{force: %{consume: nil}}, :consume), do: :ok
    defp forced(%{force: %{replay: nil}}, :replay), do: :ok
    defp forced(%{force: %{activate: reason}}, :activate), do: {:error, reason}
    defp forced(%{force: %{consume: reason}}, :consume), do: {:error, reason}
    defp forced(%{force: %{replay: reason}}, :replay), do: {:error, reason}
  end

  @now ~U[2026-07-12 18:00:00Z]
  @grant_id "018f3f56-1111-7222-8333-123456789abc"
  @principal_id "018f3f56-1111-7222-8333-123456789abf"
  @action "remote_access.ssh_ca.bundle.read"
  @required_permissions [
    "ansible.runs.launch",
    "devices.remote_access.ssh.ca_bundle.read"
  ]

  setup do
    test = self()

    {:ok, store} =
      Agent.start_link(fn ->
        %{
          grants: %{},
          uses: %{},
          audits: [],
          cleanups: %{},
          force: %{activate: nil, consume: nil, replay: nil}
        }
      end)

    attrs = attrs()
    authority = current_authority(attrs)
    {:ok, authorizer} = Agent.start_link(fn -> %{test: test, result: {:ok, authority}} end)

    {:ok, cleanup} =
      Agent.start_link(fn ->
        %{
          test: test,
          calls: [],
          result:
            {:ok,
             %{
               cleanup_status: :complete,
               job_cleanup: :not_required,
               credential_cleanup: :deleted
             }}
        }
      end)

    opts = [
      store: FakeStore,
      store_context: store,
      authorizer: FakeAuthorizer,
      authority_context: authorizer,
      cleanup: FakeCleanup,
      cleanup_context: cleanup,
      verifier_config: [
        active_key_id: "callback-v1",
        keys: %{"callback-v1" => String.duplicate("k", 32)}
      ],
      random_bytes: fn 32 -> :binary.copy(<<7>>, 32) end,
      now: @now
    ]

    %{store: store, authorizer: authorizer, cleanup: cleanup, attrs: attrs, opts: opts}
  end

  test "authorization projection retains policy evidence without exposing it to cleanup" do
    grant = %{
      id: @grant_id,
      policy_snapshot: %{"schema" => "serviceradar.automation_callback_policy/v1"},
      response_snapshot: %{"sensitive" => true},
      verifier_digest: <<1, 2, 3>>,
      launch_envelope_ref: "secret-ref"
    }

    authorization_grant = Audit.authorization_grant(grant)
    cleanup_grant = Audit.safe_grant(grant)

    assert authorization_grant.policy_snapshot == grant.policy_snapshot
    refute Map.has_key?(authorization_grant, :response_snapshot)
    refute Map.has_key?(authorization_grant, :verifier_digest)
    refute Map.has_key?(authorization_grant, :launch_envelope_ref)
    refute Map.has_key?(cleanup_grant, :policy_snapshot)
  end

  test "pending issuance returns opaque bearer and idempotency credentials once", context do
    assert {:ok, %{grant: pending, bearer: bearer, idempotency_key: idempotency_key}} =
             Lifecycle.prepare(context.attrs, context.opts)

    assert pending == %{
             id: @grant_id,
             state: :pending,
             action: @action,
             expires_at: DateTime.add(@now, 120),
             retryable: true
           }

    assert byte_size(bearer) == 43
    assert byte_size(idempotency_key) in 32..128
    assert idempotency_key != bearer
    refute inspect(pending) =~ bearer
    refute inspect(pending) =~ idempotency_key
    refute inspect(pending) =~ "verifier"

    stored = grant(context.store)
    refute Map.has_key?(stored, :bearer)
    assert stored.verifier_key_id == "callback-v1"
    assert byte_size(stored.verifier_digest) == 32
    assert stored.idempotency_verifier_key_id == "callback-v1"
    assert byte_size(stored.idempotency_verifier_digest) == 32
    refute Map.has_key?(stored, :idempotency_key)
    assert stored.policy_snapshot == context.attrs.policy_snapshot
    assert stored.dispatch_agent_id == "agent-gateway-demo"
    assert stored.launch_envelope_ref == "vault-envelope:callback-grant-1"

    state = Agent.get(context.store, & &1)
    refute inspect(state.audits) =~ bearer
    refute inspect(state.audits) =~ idempotency_key
    refute Enum.any?(state.audits, &Map.has_key?(&1, :verifier_digest))
  end

  test "pending issuance requires reviewed callback credential prompting", context do
    attrs = put_in(context.attrs, [:awx_scope_snapshot, :ask_credential_on_launch], false)

    assert {:error, :callback_credential_prompt_required} =
             Lifecycle.prepare(attrs, context.opts)

    assert Agent.get(context.store, &map_size(&1.grants)) == 0
  end

  test "SystemActor cannot be the grant authority", context do
    attrs =
      context.attrs
      |> put_in([:actor_snapshot, :principal_type], :system)
      |> put_in([:actor_snapshot, :principal_id], "system:dispatcher")

    assert {:error, :initiating_principal_required} = Lifecycle.prepare(attrs, context.opts)
    assert Agent.get(context.store, &map_size(&1.grants)) == 0
  end

  test "deployment limits cannot exceed the principal's issuance ceiling", context do
    attrs = put_in(context.attrs, [:issuance_ceiling, :max_ttl_seconds], 60)

    assert {:error, :ttl_outside_issuance_ceiling} = Lifecycle.prepare(attrs, context.opts)
    assert Agent.get(context.store, &map_size(&1.grants)) == 0
  end

  test "pending callbacks get only a sanitized retry and consume no budget", context do
    {:ok, issued} = Lifecycle.prepare(context.attrs, context.opts)

    assert {:retry,
            %{
              status: 409,
              code: "grant_pending",
              retryable: true,
              retry_after_seconds: 1
            }} =
             Lifecycle.consume(
               @grant_id,
               issued.bearer,
               issued.idempotency_key,
               request(context.attrs),
               context.opts
             )

    assert grant(context.store).budget_remaining == 1
    assert Agent.get(context.store, & &1.uses) == %{}
    assert Enum.any?(Agent.get(context.store, & &1.audits), &(&1.event == "callback_pending"))
  end

  test "pending callbacks still require the exact key and immutable request", context do
    {:ok, issued} = Lifecycle.prepare(context.attrs, context.opts)

    assert {:error, :invalid_idempotency_key} =
             Lifecycle.consume(
               @grant_id,
               issued.bearer,
               String.duplicate("x", 43),
               request(context.attrs),
               context.opts
             )

    assert {:error, :callback_request_mismatch} =
             Lifecycle.consume(
               @grant_id,
               issued.bearer,
               issued.idempotency_key,
               Map.put(request(context.attrs), "manifest_sha256", String.duplicate("0", 64)),
               context.opts
             )

    assert grant(context.store).state == :pending
    assert grant(context.store).budget_remaining == 1
  end

  test "activation binds one exact job and cannot expand its scope", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, %{outcome: :bound}} = Lifecycle.bind_credential(@grant_id, 31, context.opts)
    binding = job_binding(context.attrs)

    assert {:ok, %{state: :active, job_id: 9_001, outcome: :activated}} =
             Lifecycle.activate(@grant_id, binding, context.opts)

    assert {:ok, %{state: :active, job_id: 9_001, outcome: :existing}} =
             Lifecycle.activate(@grant_id, binding, context.opts)

    changed_job = Map.put(binding, :job_id, 9_002)

    assert {:error, :job_binding_conflict} =
             Lifecycle.activate(@grant_id, changed_job, context.opts)

    broadened = Map.put(binding, :host_limit, "farm01-pve01,other")
    assert {:error, :awx_scope_mismatch} = Lifecycle.activate(@grant_id, broadened, context.opts)
  end

  test "post-activation credential deletion is asynchronous and leaves the grant active",
       context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:ok, %{state: :active}} =
             Lifecycle.activate(@grant_id, job_binding(context.attrs), context.opts)

    Agent.update(context.cleanup, fn state ->
      %{
        state
        | result:
            {:ok,
             %{
               cleanup_status: :queued,
               job_cleanup: :not_required,
               credential_cleanup: :delete_requested
             }}
      }
    end)

    assert {:ok,
            %{
              state: :active,
              job_id: 9_001,
              cleanup_status: :queued,
              credential_status: :delete_requested
            }} = Lifecycle.delete_activated_credential(@grant_id, context.opts)

    assert grant(context.store).state == :active
    assert grant(context.store).budget_remaining == 1
    assert Agent.get(context.store, & &1.uses) == %{}

    assert Agent.get(context.store, & &1.cleanups[@grant_id]) == %{
             cleanup_status: :queued,
             cancel_status: :not_required,
             credential_status: :delete_requested
           }

    assert_receive {:delete_activated, safe_grant}
    refute Map.has_key?(safe_grant, :launch_envelope_ref)
    refute Map.has_key?(safe_grant, :verifier_digest)
  end

  test "activation rechecks current target and permission contraction", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    update_authority(context.authorizer, fn authority ->
      %{authority | permissions: ["ansible.runs.launch"]}
    end)

    assert {:error, :current_permission_denied} =
             Lifecycle.activate(@grant_id, job_binding(context.attrs), context.opts)

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, _grant}
  end

  test "launch dispatch reauthorizes a credential-bound pending grant", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:ok, %{state: :pending, launch_dispatch_authorized: true}} =
             Lifecycle.authorize_launch_dispatch(@grant_id, context.opts)

    assert_receive {:authorized, :bind_job}
    assert grant(context.store).state == :pending
  end

  test "credential creation reauthorizes the current principal before external creation",
       context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)

    assert {:ok, %{state: :pending, credential_creation_authorized: true}} =
             Lifecycle.reauthorize_credential_creation(@grant_id, context.opts)

    assert_receive {:authorized, :bind_credential}
    assert grant(context.store).state == :pending
    assert is_nil(grant(context.store).ephemeral_credential_id)
  end

  test "credential creation revokes when current permission contracted", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)

    update_authority(context.authorizer, fn authority ->
      %{authority | permissions: ["ansible.runs.launch"]}
    end)

    assert {:error, :current_permission_denied} =
             Lifecycle.reauthorize_credential_creation(@grant_id, context.opts)

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, _grant}
  end

  test "launch dispatch denies and revokes permission contraction", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    update_authority(context.authorizer, fn authority ->
      %{authority | permissions: ["ansible.runs.launch"]}
    end)

    assert {:error, :current_permission_denied} =
             Lifecycle.authorize_launch_dispatch(@grant_id, context.opts)

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, _grant}
  end

  test "pending job watchdog reauthorizes without activating callback authority", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_job(@grant_id, job_binding(context.attrs), context.opts)

    assert {:ok, %{state: :pending, binding_pending: true, reauthorized: true}} =
             Lifecycle.reauthorize_pending_job(@grant_id, context.opts)

    assert_receive {:authorized, :bind_job}
    assert grant(context.store).state == :pending
    assert grant(context.store).binding_verified == false
  end

  test "pending job watchdog revokes and requests cleanup on authority contraction", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_job(@grant_id, job_binding(context.attrs), context.opts)

    update_authority(context.authorizer, fn authority -> %{authority | enabled: false} end)

    assert {:error, :principal_disabled} =
             Lifecycle.reauthorize_pending_job(@grant_id, context.opts)

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, safe_grant}
    assert safe_grant.job_binding["job_id"] == 9_001
  end

  test "launch dispatch never revives revoked or expired grants", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:ok, %{state: :revoked}} =
             Lifecycle.revoke(@grant_id, :operator_revoked, context.opts)

    assert {:error, {:grant_not_active, :revoked}} =
             Lifecycle.authorize_launch_dispatch(@grant_id, context.opts)

    assert grant(context.store).state == :revoked
  end

  test "launch dispatch expires an elapsed grant before denial", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)
    expired_opts = Keyword.put(context.opts, :now, DateTime.add(@now, 121))

    assert {:error, :grant_expired} =
             Lifecycle.authorize_launch_dispatch(@grant_id, expired_opts)

    assert grant(context.store).state == :expired
    assert_receive {:cleanup, :expired, _grant}
  end

  test "active watchdog reauthorization revokes a disabled principal", context do
    _issued = prepare_and_activate(context)

    update_authority(context.authorizer, fn authority -> %{authority | enabled: false} end)

    assert {:error, :principal_disabled} =
             Lifecycle.reauthorize_active(@grant_id, context.opts)

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, _grant}
  end

  test "a consumed grant retains only bound terminal-watchdog authority", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    assert {:ok, %{replay: false}} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               context.opts
             )

    assert grant(context.store).state == :consumed
    assert grant(context.store).budget_remaining == 0

    assert {:error, {:grant_not_active, :consumed}} =
             Lifecycle.reauthorize_active(@grant_id, context.opts)

    for attempt <- terminal_watchdog_attempts(context.attrs) do
      resources = %{
        operation: %{id: attempt.operation_id, mutating: true},
        execution: watchdog_execution(context.attrs),
        controller: watchdog_controller(context.attrs),
        grant: grant(context.store),
        targets: [%{id: "target-1"}]
      }

      assert {:ok, :dispatched} =
               CallbackCommandDispatcher.dispatch(attempt,
                 now: @now,
                 lifecycle_opts: context.opts,
                 resource_loader: fn ^attempt -> {:ok, resources} end,
                 claim: fn ^attempt, _lease_token, _lease_expires_at, @now ->
                   {:ok, %{attempt | state: :dispatching}}
                 end,
                 awx_dispatcher: fn claimed, _controller, _request, _command_context, _opts ->
                   send(self(), {:watchdog_dispatched, claimed.purpose})
                   {:ok, %{id: claimed.command_id}}
                 end,
                 mark_dispatched: fn claimed, _lease_token, @now ->
                   {:ok, %{claimed | state: :dispatched}}
                 end
               )

      assert_receive {:watchdog_dispatched, purpose}
      assert purpose == attempt.purpose
      assert grant(context.store).state == :consumed
      assert grant(context.store).budget_remaining == 0
    end
  end

  test "adapter-reported activation races leave the pending grant inert", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)

    Agent.update(context.store, fn state ->
      put_in(state, [:force, :activate], :serialization_conflict)
    end)

    assert {:error, :serialization_conflict} =
             Lifecycle.activate(@grant_id, job_binding(context.attrs), context.opts)

    assert grant(context.store).state == :pending
    assert grant(context.store).binding_verified == false
  end

  test "credential binding is locked, reauthorized, and idempotent only for the same instance",
       context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    assert grant(context.store).ephemeral_credential_id == nil

    assert {:ok, %{outcome: :bound, credential_bound: true}} =
             Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:ok, %{outcome: :existing, credential_bound: true}} =
             Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:error, :callback_credential_conflict} =
             Lifecycle.bind_credential(@grant_id, 32, context.opts)

    assert grant(context.store).ephemeral_credential_id == 31
  end

  test "activation rejects an unbound or incorrectly combined callback credential", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)

    assert {:error, :callback_credential_not_bound} =
             Lifecycle.activate(@grant_id, job_binding(context.attrs), context.opts)

    assert {:ok, _bound} = Lifecycle.bind_credential(@grant_id, 31, context.opts)
    missing_callback = put_in(job_binding(context.attrs), [:credential_ids], [5])

    assert {:error, :credential_binding_mismatch} =
             Lifecycle.activate(@grant_id, missing_callback, context.opts)
  end

  test "response targets cannot be substituted for another canonical tuple", context do
    attrs =
      update_in(context.attrs, [:response_snapshot, :targets], fn [target] ->
        [put_in(target, [:target_identity, :canonical_device_uid], "sr:device-other")]
      end)

    {:ok, target_keys} = Authority.target_keys(attrs.response_snapshot.targets)
    attrs = put_in(attrs, [:issuance_ceiling, :target_keys], target_keys)
    update_authority(context.authorizer, &%{&1 | target_keys: target_keys})

    assert {:error, :callback_awx_target_mismatch} = Lifecycle.prepare(attrs, context.opts)
    assert Agent.get(context.store, &map_size(&1.grants)) == 0
  end

  test "the reviewed deployment maximum keeps destructive wrappers disabled", context do
    attrs =
      context.attrs
      |> put_in([:response_snapshot, :operation], "remove")
      |> put_in([:response_snapshot, :state], "absent")
      |> update_in([:response_snapshot, :targets], fn [target] ->
        [%{target | ca_keys: [], accounts: []}]
      end)

    assert {:error, :operation_outside_deployment_maximum} =
             Lifecycle.prepare(attrs, context.opts)

    assert Agent.get(context.store, &map_size(&1.grants)) == 0
  end

  test "first read commits atomically and same key replays identical bytes", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    request = request(context.attrs)

    assert {:ok, first} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request,
               context.opts
             )

    assert first.status == 200
    assert first.content_type == "application/json"
    refute first.replay
    assert first.response_digest == CanonicalJSON.sha256(first.body)

    decoded = Jason.decode!(first.body)
    assert decoded["schema_version"] == "serviceradar.remote_access.ssh_ca_bundle/v1"
    assert decoded["action"] == @action
    assert decoded["job_id"] == 9_001
    assert decoded["authorization"]["permissions"] == Enum.sort(@required_permissions)
    assert length(decoded["targets"]) == 1

    assert {:ok, contract} = ActionRegistry.fetch(@action, "1.0.0")

    assert :ok =
             contract.response_schema
             |> ExJsonSchema.Schema.resolve()
             |> ExJsonSchema.Validator.validate(decoded)

    persisted_use = Agent.get(context.store, & &1.uses[@grant_id])
    assert byte_size(persisted_use.idempotency_key_verifier) == 32
    refute Map.has_key?(persisted_use, :idempotency_key)
    refute inspect(persisted_use) =~ key

    assert {:ok, replay} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request,
               context.opts
             )

    assert replay.replay
    assert replay.body == first.body
    assert grant(context.store).state == :consumed
    assert grant(context.store).budget_remaining == 0
    assert Enum.any?(Agent.get(context.store, & &1.audits), &(&1.event == "callback_replay"))
  end

  test "active callbacks require the exact accepted AWX runtime job ID", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    expected = request(context.attrs)

    assert {:error, :callback_request_mismatch} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               Map.put(expected, "job_id", 9_002),
               context.opts
             )

    assert {:error, :invalid_callback_request} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               Map.delete(expected, "job_id"),
               context.opts
             )

    assert grant(context.store).state == :active
    assert grant(context.store).budget_remaining == 1
    assert Agent.get(context.store, & &1.uses) == %{}
  end

  test "idempotency keys follow the public credential contract", context do
    %{bearer: bearer} = prepare_and_activate(context)

    assert {:error, :invalid_idempotency_key} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               "too-short",
               request(context.attrs),
               context.opts
             )

    assert {:error, :invalid_idempotency_key} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               String.duplicate("a", 31) <> ":",
               request(context.attrs),
               context.opts
             )

    assert grant(context.store).state == :active
    assert Agent.get(context.store, & &1.uses) == %{}
  end

  test "a well-formed but unminted idempotency key is denied before first use", context do
    %{bearer: bearer} = prepare_and_activate(context)

    assert {:error, :invalid_idempotency_key} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               idempotency("wrong-first-use"),
               request(context.attrs),
               context.opts
             )

    assert grant(context.store).state == :active
    assert grant(context.store).budget_remaining == 1
    assert Agent.get(context.store, & &1.uses) == %{}
  end

  test "replay audit failure releases no cached response", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    request = request(context.attrs)

    assert {:ok, first} =
             Lifecycle.consume(@grant_id, bearer, key, request, context.opts)

    Agent.update(context.store, fn state ->
      put_in(state, [:force, :replay], :replay_audit_commit_failed)
    end)

    assert {:error, :replay_audit_commit_failed} =
             Lifecycle.consume(@grant_id, bearer, key, request, context.opts)

    assert grant(context.store).state == :consumed
    assert grant(context.store).budget_remaining == 0

    refute Enum.any?(Agent.get(context.store, & &1.audits), fn audit ->
             audit.event == "callback_replay" and audit.response_digest == first.response_digest
           end)
  end

  test "same-key changed payload and different-key replay are denied", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    request = request(context.attrs)

    assert {:ok, _first} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request,
               context.opts
             )

    changed = Map.put(request, "phase", "verify")

    assert {:error, :callback_request_mismatch} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               changed,
               context.opts
             )

    assert {:error, :invalid_idempotency_key} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               idempotency("attempt-0002"),
               request,
               context.opts
             )
  end

  test "same minted-key first-use races commit once and replay once", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    parent = self()

    tasks =
      for _attempt <- 1..2 do
        Task.async(fn ->
          result =
            Lifecycle.consume(
              @grant_id,
              bearer,
              key,
              request(context.attrs),
              context.opts
            )

          send(parent, {:race_result, result})
          result
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Enum.count(results, fn {:ok, result} -> result.replay end) == 1
    assert map_size(Agent.get(context.store, & &1.uses)) == 1
  end

  test "promotion never expands the immutable response", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    update_authority(context.authorizer, fn authority ->
      %{
        authority
        | permissions: ["platform.superuser" | authority.permissions],
          actions: ["dangerous.future.action" | authority.actions],
          target_keys: [String.duplicate("f", 64) | authority.target_keys]
      }
    end)

    assert {:ok, result} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               context.opts
             )

    response = Jason.decode!(result.body)
    assert response["authorization"]["permissions"] == Enum.sort(@required_permissions)
    assert length(response["targets"]) == 1
    refute result.body =~ "platform.superuser"
    refute result.body =~ "dangerous.future.action"
  end

  test "same-key replay is denied after current authority contracts", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)
    request = request(context.attrs)

    assert {:ok, _} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request,
               context.opts
             )

    update_authority(context.authorizer, &%{&1 | target_keys: []})

    assert {:error, :target_no_longer_authorized} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request,
               context.opts
             )

    assert grant(context.store).state == :revoked
    assert_receive {:cleanup, :revoked, _grant}
  end

  test "atomic audit failure releases no response and consumes no budget", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    Agent.update(context.store, fn state ->
      put_in(state, [:force, :consume], :audit_commit_failed)
    end)

    assert {:error, :audit_commit_failed} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               context.opts
             )

    assert grant(context.store).state == :active
    assert grant(context.store).budget_remaining == 1
    assert Agent.get(context.store, & &1.uses) == %{}
  end

  test "invalid bearer is denied without exposing it in audit", context do
    {:ok, _issued} = Lifecycle.prepare(context.attrs, context.opts)
    invalid = String.duplicate("x", 43)

    assert {:error, :invalid_callback_grant} =
             Lifecycle.consume(
               @grant_id,
               invalid,
               idempotency("attempt-0001"),
               request(context.attrs),
               context.opts
             )

    refute inspect(Agent.get(context.store, & &1.audits)) =~ invalid
  end

  test "expiry and terminal transitions remove authority before cleanup failure", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    Agent.update(context.cleanup, fn state ->
      %{
        state
        | result:
            {:error,
             %{
               cleanup_status: :partial,
               job_cleanup: :cancel_failed,
               credential_cleanup: :deleted
             }}
      }
    end)

    expired_opts = Keyword.put(context.opts, :now, DateTime.add(@now, 121))

    assert {:error, :grant_expired} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               expired_opts
             )

    assert grant(context.store).state == :expired

    cleanup = Agent.get(context.store, & &1.cleanups[@grant_id])
    assert cleanup.cleanup_status == :partial
    assert cleanup.cancel_status == :cancel_failed
    assert cleanup.credential_status == :deleted

    assert_receive {:cleanup, :expired, safe_grant}
    refute Map.has_key?(safe_grant, :verifier_digest)
    refute Map.has_key?(safe_grant, :verifier_key_id)
    refute Map.has_key?(safe_grant, :token_verifier)
    refute Map.has_key?(safe_grant, :token_pepper_version)
    refute Map.has_key?(safe_grant, :idempotency_verifier_digest)
    refute Map.has_key?(safe_grant, :idempotency_verifier_key_id)
    refute Map.has_key?(safe_grant, :launch_envelope_ref)
    refute Map.has_key?(safe_grant, :policy_snapshot)
    refute Map.has_key?(safe_grant, :response_snapshot)
  end

  test "explicit revoke and terminal job cleanup keep grants unusable", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    assert {:ok, %{state: :revoked}} =
             Lifecycle.revoke(@grant_id, :operator_revoked, context.opts)

    assert {:error, {:grant_not_active, :revoked}} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               context.opts
             )

    assert_receive {:cleanup, :revoked, _grant}

    assert Enum.any?(Agent.get(context.store, & &1.audits), fn audit ->
             audit.event == "callback_denied" and
               audit.reason == "grant_not_active:revoked"
           end)
  end

  test "terminal AWX status revokes the grant and invokes terminal cleanup", context do
    %{bearer: bearer, idempotency_key: key} = prepare_and_activate(context)

    assert {:ok, %{state: :revoked}} =
             Lifecycle.job_terminal(@grant_id, :failed, context.opts)

    assert {:error, {:grant_not_active, :revoked}} =
             Lifecycle.consume(
               @grant_id,
               bearer,
               key,
               request(context.attrs),
               context.opts
             )

    assert_receive {:cleanup, :job_terminal, _grant}
  end

  defp prepare_and_activate(context) do
    assert {:ok, issued} = Lifecycle.prepare(context.attrs, context.opts)

    assert {:ok, %{credential_bound: true}} =
             Lifecycle.bind_credential(@grant_id, 31, context.opts)

    assert {:ok, %{state: :active}} =
             Lifecycle.activate(@grant_id, job_binding(context.attrs), context.opts)

    issued
  end

  defp terminal_watchdog_attempts(attrs) do
    execution = watchdog_execution(attrs)

    base = %{
      grant_id: @grant_id,
      operation_id: attrs.parent_run_id,
      execution_id: attrs.execution_id,
      controller_id: attrs.awx_scope_snapshot.controller_id,
      dispatch_agent_id: attrs.dispatch_agent_id,
      dispatch_partition_id: attrs.dispatch_partition_id
    }

    {:ok, poll_request} = CallbackCommandContract.fetch_job_request(9_001)

    {:ok, poll_attrs} =
      CallbackCommandContract.build_attempt(base, execution, poll_request,
        stage: :fetch_job,
        purpose: :terminal_poll,
        command_type: "awx.fetch_job",
        expected_job_id: 9_001,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    terminal_job = %{"id" => 9_001, "status" => "successful"}
    {:ok, confirmation_request} = CallbackCommandContract.host_summaries_request(9_001, 1)

    {:ok, confirmation_attrs} =
      CallbackCommandContract.build_attempt(base, execution, confirmation_request,
        stage: :fetch_host_summaries,
        purpose: :terminal_confirmation,
        command_type: "awx.fetch_job_host_summaries",
        expected_job_id: 9_001,
        terminal_job_snapshot: terminal_job,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    Enum.map([poll_attrs, confirmation_attrs], fn attempt_attrs ->
      struct!(Attempt, Map.merge(attempt_attrs, %{id: Ash.UUID.generate(), state: :planned}))
    end)
  end

  defp watchdog_execution(attrs) do
    {:ok, controller_snapshot} =
      attrs |> watchdog_controller() |> ControllerSecuritySnapshot.capture()

    %{
      id: attrs.execution_id,
      operation_id: attrs.parent_run_id,
      controller_id: attrs.awx_scope_snapshot.controller_id,
      dispatch_id: "018f3f56-1111-7222-8333-123456789ac1",
      snapshot_digest: attrs.awx_scope_snapshot.snapshot_digest,
      metadata: %{
        "dispatch_partition_id" => attrs.dispatch_partition_id,
        "controller_security_snapshot" => controller_snapshot
      }
    }
  end

  defp watchdog_controller(attrs) do
    %{
      id: attrs.awx_scope_snapshot.controller_id,
      name: "callback-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: attrs.dispatch_agent_id,
      enabled: true,
      sync_credential_secret_id: "callback-sync-secret",
      execution_credential_secret_id: "callback-execution-secret",
      callback_credential_secret_id: "callback-management-secret",
      metadata: %{}
    }
  end

  defp grant(store), do: Agent.get(store, & &1.grants[@grant_id])

  defp idempotency(suffix), do: "serviceradar-callback-idempotency-#{suffix}"

  defp update_authority(authorizer, fun) do
    Agent.update(authorizer, fn state ->
      {:ok, authority} = state.result
      %{state | result: {:ok, fun.(authority)}}
    end)
  end

  defp request(attrs) do
    snapshot = attrs.response_snapshot

    %{
      "action" => @action,
      "schema_version" => "serviceradar.remote_access.ssh_ca_bundle/v1",
      "manifest_sha256" => snapshot.manifest_sha256,
      "job_id" => 9_001,
      "phase" => snapshot.phase,
      "operation" => snapshot.operation,
      "state" => snapshot.state
    }
  end

  defp job_binding(attrs) do
    attrs.awx_scope_snapshot
    |> Map.update!(:credential_ids, &Enum.uniq(&1 ++ [31]))
    |> Map.put(:job_id, 9_001)
  end

  defp attrs do
    target_identity = %{
      controller_id: "controller-demo",
      inventory_id: 34,
      awx_host_id: 7,
      canonical_device_uid: "sr:device-7"
    }

    awx_target =
      Map.merge(target_identity, %{
        membership_id: "018f3f56-1111-7222-8333-123456789ac2",
        host_name: "farm01-pve01",
        ansible_host: "192.168.2.22"
      })

    response_target = %{
      inventory_hostname: "farm01-pve01",
      inventory_address: "192.168.2.22",
      target_identity: target_identity,
      ca_keys: [
        %{
          id: "serviceradar-user-ca-2026",
          public_key:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test",
          fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        }
      ],
      accounts: [
        %{
          name: "mfreeman",
          principals: ["srp_v1_AAAAAAAAAAAAAAAAAAAA"]
        }
      ],
      transaction: %{
        id: "txn-enroll-1",
        stage_job_id: 8_999,
        generation: "generation-1",
        machine_credential_ref: "awx-credential-ref:linux-demo"
      }
    }

    %{
      id: @grant_id,
      tenant_id: "platform",
      parent_run_id: "018f3f56-1111-7222-8333-123456789abd",
      execution_id: "018f3f56-1111-7222-8333-123456789abe",
      action: @action,
      audience: "serviceradar.awx.callback/v1",
      budget: 1,
      expires_at: DateTime.add(@now, 120),
      actor_snapshot: %{
        principal_type: :human,
        principal_id: @principal_id,
        tenant_id: "platform",
        authorization_version: "role-v7"
      },
      approval_snapshot: %{
        "binding_id" => "binding-1",
        "binding_version" => 3,
        "approval_id" => "approval-1",
        "approval_expires_at" => DateTime.to_iso8601(DateTime.add(@now, 3_600)),
        "reviewed_by_principal_type" => "human",
        "reviewed_by_principal_id" => @principal_id,
        "reviewed_at" => DateTime.to_iso8601(DateTime.add(@now, -3_600)),
        "review_metadata" => %{"policy_version" => "ssh-policy-v3"},
        "issued_at" => DateTime.to_iso8601(@now)
      },
      policy_snapshot: %{
        "schema" => "serviceradar.automation_callback_policy/v1",
        "action" => @action,
        "binding_id" => "binding-1",
        "binding_version" => 3,
        "version" => "ssh-policy-v3",
        "approval_id" => "approval-1",
        "approval_state" => "approved",
        "approval_expires_at" => DateTime.to_iso8601(DateTime.add(@now, 3_600))
      },
      issuance_ceiling: issuance_ceiling([response_target]),
      awx_scope_snapshot: %{
        controller_id: "controller-demo",
        inventory_id: 34,
        job_template_id: 42,
        project_id: 3,
        scm_revision: String.duplicate("a", 40),
        content_sha256: String.duplicate("b", 64),
        execution_environment_id: 4,
        machine_credential_id: 5,
        ask_credential_on_launch: true,
        callback_credential_type_id: 6,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("c", 64),
        host_limit: "farm01-pve01",
        target_count: 1,
        target_digest: String.duplicate("d", 64),
        snapshot_digest: String.duplicate("e", 64),
        targets: [awx_target],
        binding_id: "binding-1",
        awx_created_by_id: 11,
        credential_ids: [5]
      },
      response_snapshot: %{
        manifest_sha256: String.duplicate("f", 64),
        phase: "stage",
        operation: "enroll",
        state: "present",
        targets: [response_target]
      },
      dispatch_agent_id: "agent-gateway-demo",
      dispatch_partition_id: "farm01",
      launch_envelope_ref: "vault-envelope:callback-grant-1"
    }
  end

  defp issuance_ceiling(targets) do
    {:ok, target_keys} = Authority.target_keys(targets)

    %{
      permissions: @required_permissions,
      actions: [@action],
      target_keys: target_keys,
      tenant_id: "platform",
      principal_type: :human,
      principal_id: @principal_id,
      max_ttl_seconds: 300,
      success_budget: 1
    }
  end

  defp current_authority(attrs) do
    {:ok, target_keys} = Authority.target_keys(attrs.response_snapshot.targets)
    {:ok, scope_digest} = CanonicalJSON.digest(attrs.awx_scope_snapshot)
    {:ok, approval_digest} = CanonicalJSON.digest(attrs.approval_snapshot)
    {:ok, policy_digest} = CanonicalJSON.digest(attrs.policy_snapshot)

    %{
      enabled: true,
      principal_type: :human,
      principal_id: attrs.actor_snapshot.principal_id,
      tenant_id: attrs.tenant_id,
      permissions: @required_permissions,
      actions: [@action],
      target_keys: target_keys,
      approval_digest: approval_digest,
      policy_digest: policy_digest,
      scope_digest: scope_digest,
      run_state: :running,
      job_state: :running,
      job_id: 9_001
    }
  end
end
