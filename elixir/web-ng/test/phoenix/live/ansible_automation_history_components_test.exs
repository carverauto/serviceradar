defmodule ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryComponentsTest do
  # The verified-route component needs the singleton endpoint persistent term.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryComponents

  @moduletag :db_free

  setup_all do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      case ServiceRadarWebNGWeb.Endpoint.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  test "renders controller-local scope proof, exact target tuple, ambiguity, diagnostics, and hold" do
    document =
      (&AutomationHistoryComponents.operation_detail/1)
      |> render_component(bundle: bundle(), timezone: "America/Chicago")
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, "#secure-ansible-operation-detail")) == 1
    assert Enum.count(LazyHTML.query(document, "[data-testid=secure-target-tuples]")) == 1
    assert Enum.count(LazyHTML.query(document, "[data-testid=scope-proof-verified]")) == 1
    assert Enum.count(LazyHTML.query(document, "[data-testid=secure-target-hold]")) == 1

    text = LazyHTML.text(document)
    assert text =~ "dispatch outcome is ambiguous"
    assert text =~ "AWX job (controller-local)"
    assert text =~ "farm01-awx"
    assert text =~ "controller-11111111"
    assert text =~ "membership-77777777"
    assert text =~ "sr:device-7"
    assert text =~ "scope_mismatch"
    assert text =~ "Target hold active"
    assert text =~ "Expected AWX hosts"
    assert text =~ "Observed AWX hosts"
    assert text =~ "Controller executions"
    refute text =~ "ServiceRadar secured"
    refute text =~ "Legacy"
    refute Enum.any?(LazyHTML.query(document, "a[href='/ansible/runs']"))

    times = LazyHTML.query(document, "time[data-user-time-zone='America/Chicago']")
    assert Enum.count(times) == 4

    assert LazyHTML.attribute(times, "id") == [
             "ansible-operation-operation-11111111-created-at",
             "ansible-operation-operation-11111111-started-at",
             "ansible-execution-execution-11111111-started-at",
             "ansible-execution-execution-11111111-scope-verified-at"
           ]
  end

  test "renders cancellation failure and missing scope proof as fail-closed evidence" do
    base = bundle()
    [execution] = base.executions

    canceled_bundle = %{
      base
      | operation: %{base.operation | state: :cancel_failed},
        executions: [%{execution | state: :cancel_failed, scope_verified_at: nil}]
    }

    document =
      (&AutomationHistoryComponents.operation_detail/1)
      |> render_component(bundle: canceled_bundle, timezone: "America/Chicago")
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, "[data-testid=scope-proof-pending]")) == 1

    text = LazyHTML.text(document)
    assert text =~ "cancellation failed"
    assert text =~ "Treat the operation as potentially active"
    assert text =~ "must not be treated as safe to mutate"
  end

  defp bundle do
    %{
      operation: %{
        id: "operation-11111111",
        action: "ansible.playbook.run",
        state: :dispatch_ambiguous,
        mutating: true,
        check_mode: false,
        initiator_principal_type: :human,
        initiator_principal_id: "user-42",
        request_source: "ansible_launch_live",
        target_digest: String.duplicate("a", 64),
        diagnostics: [%{key: :reason_code, label: "Reason code", value: "dispatch_ambiguous"}],
        started_at: ~U[2026-07-13 00:00:00Z],
        ended_at: nil,
        inserted_at: ~U[2026-07-13 00:00:00Z]
      },
      executions: [
        %{
          id: "execution-11111111",
          controller: %{id: "controller-11111111", name: "farm01-awx"},
          inventory_id: 34,
          job_template_id: 42,
          project_id: 3,
          scm_revision: String.duplicate("b", 40),
          content_sha256: String.duplicate("c", 64),
          execution_environment_id: 4,
          check_mode: false,
          host_limit: "farm01-web01",
          dispatch_id: "dispatch-11111111",
          snapshot_digest: String.duplicate("d", 64),
          state: :dispatch_ambiguous,
          awx_job_id: 77,
          scope_verified_at: ~U[2026-07-13 00:01:00Z],
          started_at: ~U[2026-07-13 00:00:30Z],
          ended_at: nil,
          diagnostics: [
            %{key: :expected_host_ids, label: "Expected AWX hosts", value: "7"},
            %{key: :observed_host_ids, label: "Observed AWX hosts", value: "8"}
          ],
          targets: [
            %{
              id: "target-11111111",
              controller_id: "controller-11111111",
              inventory_id: 34,
              awx_host_id: 7,
              membership_id: "membership-77777777",
              canonical_device_uid: "sr:device-7",
              membership_generation: 2,
              host_name: "farm01-web01",
              ansible_host: "192.0.2.10",
              status: :scope_mismatch,
              snapshot_digest: String.duplicate("e", 64),
              diagnostics: [
                %{key: :reason_code, label: "Reason code", value: "job_host_scope_mismatch"}
              ],
              active_hold: %{
                trigger_phase: :unknown,
                generation: 2,
                reason: "job_host_scope_mismatch",
                transaction_id: "transaction-11111111",
                evidence_digest: String.duplicate("f", 64)
              }
            }
          ]
        }
      ]
    }
  end
end
