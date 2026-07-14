defmodule ServiceRadar.Automation.Ansible.MutationLifecycle do
  @moduledoc """
  Authenticated, append-only mutation-phase state machine for AWX targets.

  Callers pass the exact bytes delivered by the trusted AWX command-result
  path. The byte digest, rather than decoded map equality, defines idempotent
  replay. Invalid, conflicting, expired, or out-of-order evidence creates an
  `unknown` outcome and a canonical-device hold through one action boundary.
  """

  alias ServiceRadar.Automation.Ansible.MutationLifecycleAshActions
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence

  @schema "automation.mutation_phase.v1"
  @max_envelope_bytes 65_536
  @phases ~w(initial staged verified committed rolled_back critical unknown)a
  @terminal_phases ~w(committed rolled_back critical unknown)a
  @hold_phases ~w(critical unknown)a
  @transitions %{
    nil => [:initial],
    initial: [:staged],
    staged: [:verified, :rolled_back, :critical, :unknown],
    verified: [:committed, :rolled_back, :critical, :unknown]
  }

  @type context :: %{
          required(:execution) => map() | struct(),
          required(:target) => map() | struct(),
          required(:action) => String.t(),
          required(:policy_digest) => String.t(),
          required(:deadline_at) => DateTime.t()
        }

  @doc """
  Records one authenticated phase envelope or fails closed to an unknown hold.

  `authenticated_source` is constructed by the mTLS command-result consumer;
  it is not read from the envelope or target stdout.
  """
  @spec record(context(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record(context, envelope_bytes, authenticated_source, opts \\ [])

  def record(context, envelope_bytes, authenticated_source, opts)
      when is_map(context) and is_binary(envelope_bytes) and is_map(authenticated_source) do
    actions = Keyword.get(opts, :actions, MutationLifecycleAshActions)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    digest = sha256(envelope_bytes)

    result =
      with :ok <- validate_context(context),
           :ok <- validate_envelope_size(envelope_bytes),
           {:ok, decoded} <- Jason.decode(envelope_bytes),
           {:ok, evidence} <- normalize_evidence(decoded, digest),
           :ok <- verify_exact_binding(context, evidence),
           {:ok, source} <- verify_authenticated_source(context, authenticated_source),
           evidence = Map.put(evidence, :authenticated_source, source),
           {:ok, replay} <- replay_status(actions, evidence),
           {:continue, evidence} <- replay,
           {:ok, phases} <- actions.list_for_target(target_id(context)),
           :ok <- validate_transition(phases, evidence, now) do
        persist_valid(actions, context, evidence)
      end

    case result do
      {:ok, %{replayed?: _}} = ok ->
        ok

      {:error, {:conflicting_replay, existing}} ->
        fail_closed(actions, context, envelope_bytes, authenticated_source, now, {
          :conflicting_replay,
          value(existing, :idempotency_key)
        })

      {:error, reason} ->
        fail_closed(actions, context, envelope_bytes, authenticated_source, now, reason)
    end
  end

  def record(_context, _envelope_bytes, _authenticated_source, _opts),
    do: {:error, :invalid_mutation_evidence}

  @doc """
  Converts an overdue non-terminal transaction into unknown plus a device hold.

  Watchdogs call this with the same immutable child/target context used for
  ingestion. Terminal outcomes and non-expired phases are left unchanged.
  """
  @spec expire(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def expire(context, opts \\ [])

  def expire(context, opts) when is_map(context) do
    actions = Keyword.get(opts, :actions, MutationLifecycleAshActions)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_context(context),
         {:ok, phases} <- actions.list_for_target(target_id(context)),
         latest when not is_nil(latest) <- latest_phase(phases) do
      phase = phase_atom(value(latest, :phase))
      deadline = value(latest, :deadline_at)

      cond do
        phase in @terminal_phases ->
          {:ok, %{phase: latest, held?: phase in @hold_phases, expired?: false}}

        not date_time?(deadline) ->
          fail_closed(actions, context, <<>>, %{}, now, :deadline_missing)

        DateTime.after?(now, deadline) ->
          attrs = unknown_attrs(context, <<>>, %{}, now, :deadline_expired, phases)

          case actions.record_unknown_and_hold(context, attrs, :deadline_expired) do
            {:ok, result} ->
              {:ok, Map.merge(result, %{held?: true, expired?: true, replayed?: false})}

            {:error, reason} ->
              {:error, {:unknown_hold_failed, reason}}
          end

        true ->
          {:ok, %{phase: latest, held?: false, expired?: false}}
      end
    else
      nil -> {:error, :mutation_phase_missing}
      {:error, _} = error -> error
    end
  end

  def expire(_context, _opts), do: {:error, :invalid_mutation_context}

  defp replay_status(actions, evidence) do
    case actions.get_by_idempotency_key(evidence.execution_target_id, evidence.idempotency_key) do
      {:ok, nil} ->
        {:ok, {:continue, evidence}}

      {:ok, existing} ->
        if value(existing, :evidence_digest) == evidence.evidence_digest do
          {:ok,
           {:ok,
            %{
              phase: existing,
              held?: phase_atom(value(existing, :phase)) in @hold_phases,
              replayed?: true
            }}}
        else
          {:error, {:conflicting_replay, existing}}
        end

      {:error, reason} ->
        {:error, {:idempotency_lookup_failed, reason}}
    end
  end

  defp persist_valid(actions, context, evidence) do
    if evidence.phase in @hold_phases do
      case actions.record_phase_and_hold(context, evidence, evidence.phase) do
        {:ok, result} ->
          {:ok, Map.merge(result, %{held?: true, replayed?: false})}

        {:error, reason} ->
          {:error, {:phase_hold_failed, reason}}
      end
    else
      case actions.record_phase(evidence) do
        {:ok, phase} -> {:ok, %{phase: phase, held?: false, replayed?: false}}
        {:error, reason} -> {:error, {:phase_record_failed, reason}}
      end
    end
  end

  defp fail_closed(actions, context, bytes, source, now, reason) do
    with :ok <- validate_context(context),
         {:ok, phases} <- actions.list_for_target(target_id(context)) do
      attrs = unknown_attrs(context, bytes, source, now, reason, phases)

      case actions.record_unknown_and_hold(context, attrs, reason) do
        {:ok, result} ->
          {:error, {:mutation_state_unknown, reason, Map.put(result, :held?, true)}}

        {:error, hold_reason} ->
          {:error, {:unknown_hold_failed, reason, hold_reason}}
      end
    end
  end

  defp validate_context(context) do
    execution = value(context, :execution)
    target = value(context, :target)
    action = value(context, :action)
    policy_digest = value(context, :policy_digest)
    deadline_at = value(context, :deadline_at)

    cond do
      not is_map(execution) or not is_map(target) ->
        {:error, :invalid_mutation_context}

      blank?(value(execution, :id)) or blank?(value(target, :id)) ->
        {:error, :invalid_mutation_context}

      value(target, :execution_id) != value(execution, :id) ->
        {:error, :target_execution_mismatch}

      value(target, :controller_id) != value(execution, :controller_id) ->
        {:error, :target_controller_mismatch}

      value(target, :inventory_id) != value(execution, :inventory_id) ->
        {:error, :target_inventory_mismatch}

      not is_integer(value(execution, :awx_job_id)) ->
        {:error, :bound_awx_job_required}

      value(execution, :state) not in [:scope_verified, :running] ->
        {:error, :scope_verification_required}

      blank?(value(target, :canonical_device_uid)) or not is_integer(value(target, :awx_host_id)) ->
        {:error, :invalid_mutation_target}

      blank?(action) or not sha256_hex?(policy_digest) or not date_time?(deadline_at) ->
        {:error, :mutation_authority_snapshot_required}

      true ->
        :ok
    end
  end

  defp validate_envelope_size(bytes) do
    if byte_size(bytes) in 1..@max_envelope_bytes,
      do: :ok,
      else: {:error, :mutation_envelope_size_invalid}
  end

  defp normalize_evidence(decoded, digest) when is_map(decoded) do
    with {:ok, transaction_id} <- required_string(decoded, :transaction_id),
         :ok <- validate_uuid(transaction_id),
         {:ok, idempotency_key} <- required_string(decoded, :idempotency_key),
         {:ok, action} <- required_string(decoded, :action),
         {:ok, scm_revision} <- required_string(decoded, :scm_revision),
         {:ok, policy_digest} <- required_sha256(decoded, :policy_digest),
         {:ok, outcome_digest} <- required_sha256(decoded, :outcome_digest),
         {:ok, phase} <- required_phase(decoded, :phase),
         {:ok, previous_phase} <- optional_phase(decoded, :previous_phase),
         {:ok, deadline_at} <- required_datetime(decoded, :deadline_at),
         {:ok, occurred_at} <- required_datetime(decoded, :occurred_at) do
      {:ok,
       %{
         execution_target_id: value(decoded, :execution_target_id),
         execution_id: value(decoded, :execution_id),
         controller_id: value(decoded, :controller_id),
         inventory_id: positive_integer(value(decoded, :inventory_id)),
         awx_job_id: positive_integer(value(decoded, :awx_job_id)),
         awx_host_id: positive_integer(value(decoded, :awx_host_id)),
         canonical_device_uid: value(decoded, :canonical_device_uid),
         transaction_id: transaction_id,
         generation: positive_integer(value(decoded, :generation)),
         idempotency_key: idempotency_key,
         previous_phase: previous_phase,
         phase: phase,
         action: action,
         template_id: positive_integer(value(decoded, :template_id)),
         scm_revision: scm_revision,
         policy_digest: policy_digest,
         outcome_digest: outcome_digest,
         evidence_digest: digest,
         deadline_at: deadline_at,
         occurred_at: occurred_at,
         metadata: %{"schema" => value(decoded, :schema)}
       }}
    end
  end

  defp normalize_evidence(_decoded, _digest), do: {:error, :invalid_mutation_envelope}

  defp verify_exact_binding(context, evidence) do
    execution = value(context, :execution)
    target = value(context, :target)

    checks = [
      {:mutation_schema_mismatch, evidence.metadata["schema"] == @schema},
      {:mutation_execution_mismatch, evidence.execution_id == value(execution, :id)},
      {:mutation_target_mismatch, evidence.execution_target_id == value(target, :id)},
      {:mutation_controller_mismatch, evidence.controller_id == value(execution, :controller_id)},
      {:mutation_inventory_mismatch, evidence.inventory_id == value(execution, :inventory_id)},
      {:mutation_job_mismatch, evidence.awx_job_id == value(execution, :awx_job_id)},
      {:mutation_host_mismatch, evidence.awx_host_id == value(target, :awx_host_id)},
      {:mutation_device_mismatch,
       evidence.canonical_device_uid == value(target, :canonical_device_uid)},
      {:mutation_action_mismatch, evidence.action == value(context, :action)},
      {:mutation_template_mismatch, evidence.template_id == value(execution, :job_template_id)},
      {:mutation_revision_mismatch, evidence.scm_revision == value(execution, :scm_revision)},
      {:mutation_policy_mismatch, evidence.policy_digest == value(context, :policy_digest)},
      {:mutation_deadline_mismatch,
       DateTime.compare(evidence.deadline_at, value(context, :deadline_at)) == :eq},
      {:mutation_generation_invalid, is_integer(evidence.generation)}
    ]

    case Enum.find(checks, fn {_reason, valid?} -> not valid? end) do
      nil -> :ok
      {reason, false} -> {:error, reason}
    end
  end

  defp verify_authenticated_source(context, source) do
    execution = value(context, :execution)
    target = value(context, :target)

    checks = [
      source_value(source, :authenticated) == true,
      source_value(source, :source_kind) == "awx_controller_lifecycle",
      source_value(source, :transport) == "mtls_edge_command",
      source_value(source, :execution_id) == value(execution, :id),
      source_value(source, :execution_target_id) == value(target, :id),
      source_value(source, :controller_id) == value(execution, :controller_id),
      source_value(source, :inventory_id) == value(execution, :inventory_id),
      source_value(source, :awx_job_id) == value(execution, :awx_job_id),
      source_value(source, :awx_host_id) == value(target, :awx_host_id),
      source_value(source, :template_id) == value(execution, :job_template_id),
      source_value(source, :scm_revision) == value(execution, :scm_revision),
      source_value(source, :action) == value(context, :action),
      source_value(source, :policy_digest) == value(context, :policy_digest),
      not blank?(source_value(source, :command_id))
    ]

    if Enum.all?(checks) do
      {:ok,
       Map.take(source, [
         :source_kind,
         :transport,
         :authenticated,
         :execution_id,
         :execution_target_id,
         :controller_id,
         :inventory_id,
         :awx_job_id,
         :awx_host_id,
         :template_id,
         :scm_revision,
         :action,
         :policy_digest,
         :command_id,
         "source_kind",
         "transport",
         "authenticated",
         "execution_id",
         "execution_target_id",
         "controller_id",
         "inventory_id",
         "awx_job_id",
         "awx_host_id",
         "template_id",
         "scm_revision",
         "action",
         "policy_digest",
         "command_id"
       ])}
    else
      {:error, :unauthenticated_mutation_evidence}
    end
  end

  defp validate_transition(phases, evidence, now) do
    latest = latest_phase(phases)
    previous = phase_atom(value(latest, :phase))
    expected_generation = if latest, do: value(latest, :generation) + 1, else: 1

    expected_transaction =
      if latest, do: value(latest, :transaction_id), else: evidence.transaction_id

    allowed = Map.get(@transitions, previous, [])

    cond do
      not date_time?(now) ->
        {:error, :invalid_mutation_clock}

      evidence.previous_phase != previous ->
        {:error, :mutation_previous_phase_mismatch}

      evidence.phase not in allowed ->
        {:error, :mutation_transition_invalid}

      evidence.generation != expected_generation ->
        {:error, :mutation_generation_mismatch}

      evidence.transaction_id != expected_transaction ->
        {:error, :mutation_transaction_mismatch}

      DateTime.after?(evidence.occurred_at, evidence.deadline_at) ->
        {:error, :mutation_evidence_after_deadline}

      DateTime.after?(now, evidence.deadline_at) ->
        {:error, :mutation_deadline_expired}

      true ->
        :ok
    end
  end

  defp unknown_attrs(context, bytes, source, now, reason, phases) do
    execution = value(context, :execution)
    target = value(context, :target)
    latest = latest_phase(phases)
    digest = sha256(bytes)
    transaction_id = value(latest, :transaction_id) || Ash.UUID.generate()
    generation = (value(latest, :generation) || 0) + 1
    previous = phase_atom(value(latest, :phase))

    %{
      execution_target_id: value(target, :id),
      transaction_id: transaction_id,
      generation: generation,
      idempotency_key: "unknown:" <> digest <> ":" <> Integer.to_string(generation),
      previous_phase: previous,
      phase: :unknown,
      action: value(context, :action),
      template_id: value(execution, :job_template_id),
      scm_revision: value(execution, :scm_revision),
      policy_digest: value(context, :policy_digest),
      outcome_digest: digest,
      evidence_digest: digest,
      authenticated_source: safe_source(source),
      deadline_at: now,
      occurred_at: now,
      metadata: %{
        "schema" => @schema,
        "failure_reason" => SafeFailureEvidence.code(reason),
        "fail_closed" => true
      }
    }
  end

  defp latest_phase([]), do: nil

  defp latest_phase(phases) do
    Enum.max_by(phases, fn phase ->
      {value(phase, :generation) || 0, value(phase, :occurred_at) || ~U[1970-01-01 00:00:00Z]}
    end)
  end

  defp target_id(context), do: context |> value(:target) |> value(:id)

  defp safe_source(source) when is_map(source) do
    %{
      "source_kind" => source_value(source, :source_kind),
      "transport" => source_value(source, :transport),
      "command_id" => source_value(source, :command_id)
    }
  end

  defp safe_source(_), do: %{}

  defp required_string(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:mutation_field_invalid, key}}
    end
  end

  defp required_sha256(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        if sha256_hex?(value),
          do: {:ok, value},
          else: {:error, {:mutation_field_invalid, key}}

      _ ->
        {:error, {:mutation_field_invalid, key}}
    end
  end

  defp required_phase(map, key) do
    case phase_atom(value(map, key)) do
      phase when phase in @phases -> {:ok, phase}
      _ -> {:error, {:mutation_field_invalid, key}}
    end
  end

  defp optional_phase(map, key) do
    case value(map, key) do
      nil -> {:ok, nil}
      value -> required_phase(%{key => value}, key)
    end
  end

  defp required_datetime(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, 0} -> {:ok, datetime}
          _ -> {:error, {:mutation_field_invalid, key}}
        end

      %DateTime{} = datetime ->
        {:ok, datetime}

      _ ->
        {:error, {:mutation_field_invalid, key}}
    end
  end

  defp validate_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :mutation_transaction_id_invalid}
    end
  end

  defp phase_atom(value) when value in @phases, do: value
  defp phase_atom("initial"), do: :initial
  defp phase_atom("staged"), do: :staged
  defp phase_atom("verified"), do: :verified
  defp phase_atom("committed"), do: :committed
  defp phase_atom("rolled_back"), do: :rolled_back
  defp phase_atom("critical"), do: :critical
  defp phase_atom("unknown"), do: :unknown
  defp phase_atom(_), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp date_time?(%DateTime{}), do: true
  defp date_time?(_), do: false

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256_hex?(value) when is_binary(value) do
    byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  end

  defp sha256_hex?(_), do: false

  defp blank?(value), do: value in [nil, ""]

  defp source_value(map, key), do: value(map, key)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil
end
