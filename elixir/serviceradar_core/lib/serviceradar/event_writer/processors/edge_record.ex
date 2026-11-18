defmodule ServiceRadar.EventWriter.Processors.EdgeRecord do
  @moduledoc """
  Projects edge records delivered through the gateway and JetStream.

  The record's output contract selects its projector from `ServiceRadar.Edge.ContractCatalog`
  (a `ServiceRadar.Edge.Projector`); the processor names no contract, and an uncataloged
  contract is refused. For every record it then claims the delivery slot and the event ledger
  in one transaction, with the projector's own writes inside it.

    * A projector's side effect outside the database (`publish/3`, for example a republish to
      the metrics stream) runs BEFORE the transaction, only for a fresh primary delivery, so no
      network call runs inside a database transaction. A replay or an audit delivery is not
      published. `{:settled, reason}` skips domain writes, commits the delivery slot and
      ledger row, and counts `:settled` in `PipelineStats`. `{:refused, reason}` fails with
      `EdgeRecordRefusedError` for first-delivery dead-lettering; any `{:error, reason}` raises
      so JetStream redelivers. A republish the broker denied raises
      `ServiceRadar.NATS.PublishDeniedError`, which the pipeline dead-letters at once
      (`ServiceRadar.EventWriter.EdgeRecordDeadLetter.due?/1`).

  Each record of a batch succeeds or fails on its own (`process_batch/1`). A record that raises
  is the only one redelivered; the records before and after it are acknowledged. A record
  `ingest/4` refuses is failed as `ServiceRadar.EventWriter.EdgeRecordRefusedError`, which the
  pipeline dead-letters on its first delivery: no failure acknowledges a record unrecorded. A
  decode that is transient (`ServiceRadar.Edge.WireDecode.transient?/1`: a schema not deployed
  yet, a decoder fault), from the record frame, its body or a persisted plan a projector reads, is
  not a refusal: it fails as `ServiceRadar.EventWriter.EdgeRecordTransientError` and is
  redelivered like any other failure. So does a `publish/3` failure that wraps a
  `ServiceRadar.Dgraph.TransientError` (a Dgraph timeout or leader election).
    * A projector's database writes (`project/4`) run inside the transaction, told whether the
      delivery is primary. Completed projection replays make no domain changes; a deferred
      recovery projection revisits its durable state. Audit deliveries remain ledger-only.
      A deferred projection commits its receipt and audit before requesting redelivery.

  Recovery control deliveries have no dead-letter route. Refusals and committed deferrals
  retain their broker delivery, even beyond the ordinary delivery-count threshold.

  An audit delivery claims its slot and ledger row and projects nothing. It is a
  `LATE_FENCED_DELIVERY` record, or a `LATE_ADMISSION` record whose grant decided AUDIT. The
  same processor consumes the audit route (`telemetry.edge-record-audit.v1.*`), where the gateway
  publishes only audit deliveries, and a record there that is not one is refused.

  ## Late admission

  A `LATE_ADMISSION` delivery (openspec add-edge-production-time-admission, Decision 7) carries
  core's signed late-admission grant in `Sr-Edge-Late-Admission-Grant`. Before anything else
  reads the record, `ServiceRadar.Edge.LateAdmission.verify_delivered/3` checks that the grant
  digests to the provenance proof, is signed by core's issuer key and binds this record, and the
  publication it decided must match the route: PRIMARY on the primary route, AUDIT on the audit
  route. A PRIMARY record whose authority interval has since ended `certificate_revoked` or
  `revoked_cause_unknown` is refused, as a live record whose grant was revoked is. The ledger row
  the delivery claims records the late audit trail: admission `late`, `produced_at`, publication,
  reason, the grant's issuer key id and the publishing gateway. A grant header on any other
  delivery is refused.

  The gateway owns signature verification; projectors check the persisted authority again
  before writing authoritative domain state.

  ## Test-only ingest hook

  `//integration_tests/edge_record:vertical_slice_test` must force a real CNPG
  rollback after broker delivery, and a real consumer redelivery of a message
  whose transaction already committed, through the production JetStream
  consumer. Neither can be triggered deterministically from outside the BEAM,
  so `ingest/4` accepts a `:test_hook` option: a 3-arity fun called as
  `hook.(point, event_id, result)` at two points.

    * `:before_commit` -- inside the transaction, after every write succeeded,
      with `{:ok, ledger_outcome}`. Raising here rolls the whole transaction
      back.
    * `:transaction_result` -- after the transaction returned, with
      `{:ok, outcome}` or `{:error, reason}`. Raising here fails the record
      after a commit, so the pipeline NAKs a message whose rows are durable.

  The EventWriter pipeline reads the hook from the
  `:serviceradar_core, :edge_record_ingest_test_hook` application env. No
  config file sets that key, so production passes `nil` and both points are
  no-ops. Only code already running inside the node, such as the release
  `rpc` command the harness uses, can install it.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Dgraph.TransientError
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.LateAdmission
  alias ServiceRadar.Edge.PipelineStats
  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter
  alias ServiceRadar.EventWriter.EdgeRecordDeferredError
  alias ServiceRadar.EventWriter.EdgeRecordRefusedError
  alias ServiceRadar.EventWriter.EdgeRecordTransientError
  alias ServiceRadar.NATS.PublishDeniedError
  alias ServiceRadar.Repo

  require Logger

  @ash_inputs [Ash.Changeset, Ash.Query, Ash.ActionInput]

  @impl true
  def table_name, do: "event_ledger"

  @doc """
  Ingests each record on its own. Returns `{:ok, count}` when none raised, else
  `{:incomplete, count, failures}` naming each record that raised with its exception, so only
  those are redelivered (or dead-lettered), and each refused record with its
  `ServiceRadar.EventWriter.EdgeRecordRefusedError`, so it is dead-lettered at once. `count` is the
  records ingested.
  """
  @impl true
  def process_batch(messages, batch_opts \\ []) do
    {count, failures} =
      Enum.reduce(messages, {0, []}, fn message, {count, failures} ->
        case process_one(message, batch_opts) do
          {:ok, ingested} -> {count + ingested, failures}
          {:failed, reason} -> {count, [{message, reason} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, count}
      failures -> {:incomplete, count, Enum.reverse(failures)}
    end
  end

  # Each outcome is also counted per output contract (`ServiceRadar.Edge.PipelineStats`).
  defp process_one(%{data: data} = message, batch_opts) when is_binary(data) do
    decoded = WireDecode.decode_record(data)
    process_one(message, decoded, contract_of(decoded), batch_opts)
  end

  defp process_one(_message, _batch_opts), do: {:ok, 0}

  defp process_one(%{data: data, metadata: metadata} = message, decoded, contract, batch_opts) do
    headers = Map.get(metadata || %{}, :headers, %{})
    repo = Keyword.get(batch_opts, :repo, Repo)
    extra_opts = Keyword.get(batch_opts, :projector_opts, [])

    opts =
      Keyword.merge(extra_opts,
        test_hook: test_hook(),
        publication: publication_of(metadata)
      )

    case ingest_decoded_with_disposition(data, decoded, headers, repo, opts) do
      {:ok, {:deferred, state}} ->
        {:failed, %EdgeRecordDeferredError{state: state}}

      {:ok, disposition, outcome} when disposition in [:projected, :settled] ->
        if outcome == :inserted and opts[:publication] == :primary,
          do: PipelineStats.record(disposition, contract)

        :telemetry.execute(
          [:serviceradar, :event_writer, :edge_record, :ingested],
          %{count: 1},
          %{outcome: outcome}
        )

        {:ok, 1}

      {:error, reason} ->
        if WireDecode.transient?(reason) do
          raise EdgeRecordTransientError, reason: reason
        end

        PipelineStats.record(:projector_refused, contract)
        refused(message, EdgeRecordRefusedError.exception(reason: reason))
    end
  rescue
    # The broker's denial is logged once per subject and hold (`BrokerErrorLogFilter`), not
    # once per record.
    denied in PublishDeniedError ->
      PipelineStats.record(:failed, contract)
      {:failed, denied}

    # A transient failure is logged by the pipeline, at warning and rate-limited
    # (`ServiceRadar.EventWriter.Pipeline`), not as an error for every record. Past the
    # stream's threshold it is dead-lettered, and the dead-letter is logged as an error.
    transient in EdgeRecordTransientError ->
      PipelineStats.record(:failed, contract)
      {:failed, transient}

    e ->
      PipelineStats.record(:failed, contract)
      Logger.error("Edge record failed: #{inspect(e)}")
      {:failed, e}
  end

  # A refused record is dead-lettered on its first delivery: redelivering the same bytes is
  # refused the same way, and acknowledging it would lose the record with nothing to inspect or
  # replay. Only a delivery that has no dead-letter (`EdgeRecordDeadLetter.applies?/1` is false,
  # which neither edge-record stream's deliveries are) is still acknowledged, and says so.
  defp refused(message, %EdgeRecordRefusedError{reason: reason} = refusal) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :edge_record, :rejected],
      %{count: 1},
      %{reason: inspect(reason)}
    )

    cond do
      recovery_message?(message) ->
        Logger.warning(
          "Recovery control refused; retaining delivery: #{Exception.message(refusal)}"
        )

        {:failed, refusal}

      EdgeRecordDeadLetter.applies?(message) ->
        Logger.debug("Edge record rejected; dead-lettering it: #{Exception.message(refusal)}")
        {:failed, refusal}

      true ->
        Logger.warning(
          "Edge record rejected on a subject without a dead-letter route; acknowledging it: " <>
            Exception.message(refusal)
        )

        {:ok, 0}
    end
  end

  defp recovery_message?(%{metadata: %{subject: "telemetry.edge-record-recovery.v1"}}), do: true
  defp recovery_message?(_), do: false

  defp contract_of({:ok, record}), do: PipelineStats.contract_ref(record)
  defp contract_of({:error, _reason}), do: nil

  # The audit route carries only audit deliveries; `ingest/4` refuses anything else there.
  defp publication_of(%{subject: "telemetry.edge-record-audit." <> _}), do: :audit
  defp publication_of(_metadata), do: :primary

  @doc """
  Decodes one raw edge-record frame (`record_bytes`, exactly what a gateway
  publishes to JetStream per design.md) plus its transport headers, and runs
  the idempotent ledger/delivery-slot/sweep-batch-slot/domain-projection
  transaction described in the moduledoc.

  Returns `{:ok, :inserted | :replay}`, `{:ok, {:deferred, :pending | :blocked}}`
  after committed retryable work, or `{:error, reason}`.
  """
  @spec ingest(binary(), map() | list(), module(), keyword()) ::
          {:ok, :inserted | :replay | {:deferred, :pending | :blocked}} | {:error, term()}
  def ingest(record_bytes, headers, repo \\ Repo, opts \\ []) when is_binary(record_bytes) do
    case ingest_decoded_with_disposition(
           record_bytes,
           WireDecode.decode_record(record_bytes),
           headers,
           repo,
           opts
         ) do
      {:ok, _disposition, outcome} -> {:ok, outcome}
      {:ok, {:deferred, _state}} = deferred -> deferred
      {:error, _reason} = error -> error
    end
  end

  defp ingest_decoded_with_disposition(record_bytes, decoded, headers, repo, opts) do
    route = Keyword.get(opts, :publication, :primary)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    with {:ok, header_set} <- PublicationIdentity.extract_header_set(headers),
         {:ok, provenance} <-
           PublicationIdentity.decode_transport_provenance(header_set.provenance),
         {:edge, slot} <- {provenance.kind, provenance.slot},
         :ok <- audit_route_mode(route, provenance),
         {:ok, %EdgeRecordV1{} = record} <- decoded,
         :ok <- check_slot_matches_record(slot, record),
         {:ok, late} <-
           late_admission(repo, header_set, provenance, record, record_sha256, route),
         delivery = delivery(provenance, late, header_set.gateway_id),
         {:ok, projector} <- projector_for(record),
         {:ok, body} <- projector.decode(record),
         {:ok, publish_disposition} <-
           publish_fresh(
             repo,
             delivery,
             record,
             projector,
             body,
             Keyword.put(opts, :gateway_id, header_set.gateway_id)
           ) do
      run_transaction(
        repo,
        delivery,
        record,
        {projector, body},
        publish_disposition,
        record_sha256,
        opts
      )
    else
      {:service, _slot} -> {:error, :unsupported_slot_kind}
      {:error, _reason} = err -> err
    end
  end

  # A record on the audit route reaches the ledger only, kept there by a non-authoritative stamp:
  # LATE_FENCED_DELIVERY, or LATE_ADMISSION under a grant that decided AUDIT (`late_admission/6`
  # checks the grant). A record on that route without either stamp is refused rather than
  # projected.
  defp audit_route_mode(:audit, provenance) do
    if provenance.delivery_mode in [
         PublicationIdentity.mode_late_fenced(),
         PublicationIdentity.mode_late_admission()
       ],
       do: :ok,
       else: {:error, :audit_delivery_mode}
  end

  defp audit_route_mode(:primary, _provenance), do: :ok

  # The decision a LATE_ADMISSION record is ingested under is the one in core's signed grant, never
  # the gateway's word: the grant must verify and bind this record, and its publication must be the
  # route's. A PRIMARY record whose interval a revocation has since ended is refused, as a live
  # record whose grant was revoked is (`OutputGrants.check_current/5`). Every other delivery
  # carries no grant.
  defp late_admission(repo, header_set, provenance, record, record_sha256, route) do
    late_mode? = provenance.delivery_mode == PublicationIdentity.mode_late_admission()

    case {late_mode?, header_set.late_admission_grant} do
      {false, nil} ->
        {:ok, nil}

      {false, _grant} ->
        {:error, :late_admission_grant_unexpected}

      {true, nil} ->
        {:error, :late_admission_grant_missing}

      {true, header} ->
        delivery = %{
          record: record,
          record_sha256: record_sha256,
          slot: provenance.slot,
          proof: provenance.delivery_proof
        }

        with {:ok, grant} <- PublicationIdentity.decode_late_admission_grant(header),
             {:ok, late} <- LateAdmission.verify_delivered(grant, delivery, issuer_key!()),
             :ok <- late_route(late, route) do
          late_authority(repo, record, late)
        end
    end
  end

  defp late_route(%{publication: route}, route), do: :ok
  defp late_route(_late, _route), do: {:error, :late_admission_publication_route}

  defp late_authority(repo, record, %{publication: :primary} = late) do
    context = record.producer_context

    if LateAdmission.revoked_interval?(
         repo,
         context.producer_assignment_id,
         context.authority_epoch || 0
       ),
       do: {:error, :certificate_revoked_interval},
       else: {:ok, late}
  end

  defp late_authority(_repo, _record, late), do: {:ok, late}

  # The key core signs late grants with. A key that cannot be read now is not the record's fault,
  # so the record is redelivered rather than refused.
  defp issuer_key! do
    case IssuerKey.configured() do
      {:ok, key} -> key
      {:error, reason} -> raise EdgeRecordTransientError, reason: {:issuer_key, reason}
    end
  end

  # How this delivery is ingested: its transport slot, whether it is an audit delivery (ledger
  # only), its late-admission decision, and the publishing gateway.
  defp delivery(provenance, late, gateway_id) do
    %{
      slot: provenance.slot,
      audit?:
        provenance.delivery_mode == PublicationIdentity.mode_late_fenced() or
          match?(%{publication: :audit}, late),
      late: late,
      gateway_id: gateway_id
    }
  end

  defp check_slot_matches_record(slot, %EdgeRecordV1{producer_context: producer_context} = record) do
    cond do
      slot.network_scope_id != record.network_scope_id ->
        {:error, :network_scope_mismatch}

      is_nil(producer_context) or
          slot.authenticated_agent_id != producer_context.origin_principal_id ->
        {:error, :agent_mismatch}

      true ->
        :ok
    end
  end

  # The record's contract selects its projector from the catalog; the processor names no
  # contract. An uncataloged contract is refused.
  defp projector_for(%EdgeRecordV1{
         output_contract: %{contract_id: id, contract_version: version}
       }) do
    case ContractCatalog.projector({id, version}) do
      {:ok, projector} -> {:ok, projector}
      :error -> {:error, :unsupported_payload_family}
    end
  end

  defp projector_for(_record), do: {:error, :unsupported_payload_family}

  # A projector's side effect outside the database runs before the ledger transaction, so the
  # transaction never holds a connection across a network round trip. It runs only for a fresh
  # primary delivery: not for a record the ledger already holds (a replay) and not for an audit
  # delivery. A refusal is returned like a projection refusal; any other failure
  # raises, so the record fails and JetStream redelivers it.
  defp publish_opts(repo, opts) do
    [repo: repo, gateway_id: Keyword.get(opts, :gateway_id)] ++
      Keyword.take(opts, [
        :request,
        :flow_attribution_publisher,
        :otlp_relay_publisher,
        :check_grant_fn,
        :partition_lookup_fn,
        :agent_lookup_fn,
        :ingestor_opts,
        :cleanup_artifacts_fn,
        :persist_snapshot_fn,
        :ingest_scan_fn
      ])
  end

  defp publish_fresh(repo, delivery, record, projector, body, opts) do
    cond do
      not function_exported?(projector, :publish, 3) ->
        {:ok, :projected}

      delivery.audit? ->
        {:ok, :projected}

      fetch_ledger(repo, record.network_scope_id, record.event_id) != nil ->
        {:ok, :projected}

      true ->
        case projector.publish(record, body, publish_opts(repo, opts)) do
          :ok -> {:ok, :projected}
          {:settled, _reason} -> {:ok, :settled}
          {:refused, reason} -> {:error, EdgeRecordRefusedError.normalize_reason(reason)}
          {:error, reason} -> raise_publish_failure(reason)
        end
    end
  end

  # A failure that wraps a transient Dgraph error (a timeout or a leader election) is not the
  # record's fault: it fails as `EdgeRecordTransientError`, redelivered with backoff and logged
  # as the transient condition it is. Any other failure is unexplained and raises as an error.
  defp raise_publish_failure(reason) do
    cond do
      denied = PublishDeniedError.find(reason) -> raise denied
      TransientError.find(reason) -> raise EdgeRecordTransientError, reason: reason
      true -> raise "edge record publish failed: #{inspect(reason)}"
    end
  end

  defp run_transaction(
         repo,
         delivery,
         record,
         {projector, body},
         publish_disposition,
         record_sha256,
         opts
       ) do
    network_scope_id = record.network_scope_id
    event_id = record.event_id
    semantic_digest = record.semantic_envelope_sha256
    test_hook = Keyword.get(opts, :test_hook)

    # Ash actions a projector runs here queue their notifications until this
    # transaction commits (`NotificationQueue`).
    result =
      NotificationQueue.with_queue(fn ->
        repo.transaction(fn ->
          with {:ok, _slot_outcome} <-
                 upsert_delivery_slot(
                   repo,
                   delivery.slot,
                   record_sha256,
                   event_id,
                   semantic_digest
                 ),
               {:ok, ledger_outcome} <-
                 upsert_ledger(
                   repo,
                   {network_scope_id, event_id},
                   semantic_digest,
                   record_sha256,
                   delivery
                 ),
               {:ok, outcome} <-
                 transaction_projection_step(
                   repo,
                   delivery,
                   record,
                   projector,
                   body,
                   publish_disposition,
                   ledger_outcome
                 ) do
            run_test_hook(test_hook, :before_commit, event_id, {:ok, hook_outcome(outcome)})
            outcome
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end)

    run_test_hook(test_hook, :transaction_result, event_id, normalize_hook_result(result))

    case result do
      {:ok, {:deferred, _state}} = deferred ->
        deferred

      {:ok, {disposition, ledger_outcome}} when disposition in [:projected, :settled] ->
        if primary?(delivery, ledger_outcome) and function_exported?(projector, :committed, 3) do
          projector.committed(record, body, %{
            ledger: ledger_outcome,
            primary?: true,
            audit?: false,
            gateway_id: delivery.gateway_id,
            projection: disposition,
            projector_opts: opts
          })
        end

        {:ok, disposition, ledger_outcome}

      {:error, {:__projector_refused__, normalized_reason}} ->
        {:error, normalized_reason}

      {:error, %EdgeRecordTransientError{} = transient} ->
        raise transient

      {:error, :rollback} ->
        raise "edge record transaction #{inspect(event_id)} rolled back"

      {:error, reason} ->
        if write_failure?(reason) do
          raise "edge record transaction #{inspect(event_id)} failed: #{describe_failure(reason)}"
        else
          {:error, EdgeRecordRefusedError.normalize_reason(reason)}
        end
    end
  end

  defp transaction_projection_step(
         _repo,
         _delivery,
         _record,
         _projector,
         _body,
         :settled,
         ledger_outcome
       ) do
    {:ok, {:settled, ledger_outcome}}
  end

  defp transaction_projection_step(
         repo,
         delivery,
         record,
         projector,
         body,
         :projected,
         ledger_outcome
       ) do
    projection_outcome(
      project(repo, delivery, record, projector, body, ledger_outcome),
      ledger_outcome
    )
  end

  defp hook_outcome({disposition, ledger_outcome}) when disposition in [:projected, :settled],
    do: ledger_outcome

  defp hook_outcome(other), do: other

  defp normalize_hook_result({:ok, outcome}), do: {:ok, hook_outcome(outcome)}

  defp normalize_hook_result({:error, {:__projector_refused__, reason}}), do: {:error, reason}

  defp normalize_hook_result(other), do: other

  # A refusal names why the record cannot project: an atom, or a tuple tagged with one
  # (`{:delivery_slot_conflict, existing}`, `:gateway_unknown`). A write that failed
  # is an exception or the changeset, query or input an Ash action rolled the transaction back
  # with (a constraint race, a deadlock, a timeout): the same record can succeed on redelivery,
  # so it raises and JetStream redelivers it with backoff, then dead-letters it at its threshold.
  # A failed bulk write and a caught exit or throw are write failures too, whatever they carry.
  defp write_failure?(reason) when is_exception(reason), do: true
  defp write_failure?(%struct{}) when struct in @ash_inputs, do: true
  defp write_failure?(%Ash.BulkResult{}), do: true
  defp write_failure?({kind, _reason}) when kind in [:exit, :throw], do: true
  defp write_failure?(reason) when is_list(reason), do: Enum.any?(reason, &write_failure?/1)

  defp write_failure?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&write_failure?/1)

  defp write_failure?(_reason), do: false

  defp describe_failure(%struct{errors: errors}) when struct in @ash_inputs,
    do: errors |> Ash.Error.to_error_class() |> Exception.message()

  defp describe_failure(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe_failure(reason), do: inspect(reason, limit: 8, printable_limit: 256)

  defp project(repo, delivery, record, projector, body, ledger_outcome) do
    if function_exported?(projector, :project, 4) do
      projector.project(repo, record, body, %{
        ledger: ledger_outcome,
        primary?: primary?(delivery, ledger_outcome),
        audit?: delivery.audit?,
        gateway_id: delivery.gateway_id
      })
    else
      :ok
    end
  end

  defp projection_outcome(:ok, ledger_outcome), do: {:ok, {:projected, ledger_outcome}}

  defp projection_outcome({:settled, _reason}, ledger_outcome),
    do: {:ok, {:settled, ledger_outcome}}

  defp projection_outcome({:defer, state}, _ledger_outcome) when state in [:pending, :blocked],
    do: {:ok, {:deferred, state}}

  defp projection_outcome({:refused, reason}, _ledger_outcome),
    do: {:error, {:__projector_refused__, EdgeRecordRefusedError.normalize_reason(reason)}}

  defp projection_outcome({:error, _} = error, _ledger_outcome), do: error

  # A fresh delivery that is not an audit delivery is the one that writes domain state.
  defp primary?(delivery, ledger_outcome), do: ledger_outcome == :inserted and not delivery.audit?

  defp run_test_hook(nil, _point, _event_id, _result), do: :ok

  defp run_test_hook(hook, point, event_id, result) when is_function(hook, 3) do
    hook.(point, event_id, result)
    :ok
  end

  defp test_hook, do: Application.get_env(:serviceradar_core, :edge_record_ingest_test_hook)

  defp upsert_delivery_slot(repo, slot, record_sha256, event_id, semantic_digest) do
    sql = """
    INSERT INTO platform.edge_delivery_slots
      (network_scope_id, authenticated_agent_id, spool_id, sequence, record_sha256, event_id, semantic_envelope_sha256)
    VALUES ($1::uuid, $2::bytea, $3::uuid, $4::bigint, $5::bytea, $6::uuid, $7::bytea)
    ON CONFLICT (network_scope_id, authenticated_agent_id, spool_id, sequence) DO UPDATE
      SET record_sha256 = platform.edge_delivery_slots.record_sha256
    WHERE platform.edge_delivery_slots.record_sha256 = EXCLUDED.record_sha256
    RETURNING (xmax = 0) AS fresh_insert
    """

    params = [
      slot.network_scope_id,
      slot.authenticated_agent_id,
      slot.spool_id,
      slot.sequence,
      record_sha256,
      event_id,
      semantic_digest
    ]

    case repo.query!(sql, params) do
      %{rows: [[true]]} ->
        {:ok, :inserted}

      %{rows: [[false]]} ->
        {:ok, :replay}

      %{rows: []} ->
        {:error, {:delivery_slot_conflict, fetch_delivery_slot(repo, slot)}}
    end
  end

  defp fetch_delivery_slot(repo, slot) do
    sql = """
    SELECT record_sha256, event_id, semantic_envelope_sha256
    FROM platform.edge_delivery_slots
    WHERE network_scope_id = $1::uuid
      AND authenticated_agent_id = $2::bytea
      AND spool_id = $3::uuid
      AND sequence = $4::bigint
    """

    params = [slot.network_scope_id, slot.authenticated_agent_id, slot.spool_id, slot.sequence]

    case repo.query!(sql, params) do
      %{rows: [[record_sha256, event_id, semantic_envelope_sha256]]} ->
        %{
          record_sha256: record_sha256,
          event_id: event_id,
          semantic_envelope_sha256: semantic_envelope_sha256
        }

      %{rows: []} ->
        nil
    end
  end

  # The row a delivery claims carries its late-admission audit trail when it was admitted late. A
  # replay leaves the row that first claimed the event id as it is, live or late.
  defp upsert_ledger(repo, {network_scope_id, event_id}, semantic_digest, record_sha256, delivery) do
    sql = """
    INSERT INTO platform.event_ledger
      (network_scope_id, event_id, semantic_envelope_sha256, record_sha256, admission,
       late_produced_at, late_publication, late_reason, late_grant_issuer_key_id, late_gateway_id)
    VALUES ($1::uuid, $2::uuid, $3::bytea, $4::bytea, $5, $6, $7, $8, $9::bytea, $10)
    ON CONFLICT (network_scope_id, event_id) DO UPDATE
      SET semantic_envelope_sha256 = platform.event_ledger.semantic_envelope_sha256
    WHERE platform.event_ledger.semantic_envelope_sha256 = EXCLUDED.semantic_envelope_sha256
    RETURNING (xmax = 0) AS fresh_insert
    """

    params =
      [network_scope_id, event_id, semantic_digest, record_sha256] ++
        ledger_admission(delivery)

    case repo.query!(sql, params) do
      %{rows: [[true]]} ->
        {:ok, :inserted}

      %{rows: [[false]]} ->
        {:ok, :replay}

      %{rows: []} ->
        {:error, {:event_id_conflict, fetch_ledger(repo, network_scope_id, event_id)}}
    end
  end

  defp ledger_admission(%{late: nil}), do: ["live", nil, nil, nil, nil, nil]

  defp ledger_admission(%{late: late, gateway_id: gateway_id}) do
    [
      "late",
      late.produced_at,
      Atom.to_string(late.publication),
      Atom.to_string(late.reason),
      late.issuer_key_id,
      gateway_id
    ]
  end

  defp fetch_ledger(repo, network_scope_id, event_id) do
    case repo.query!(
           "SELECT semantic_envelope_sha256, record_sha256 FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
           [network_scope_id, event_id]
         ) do
      %{rows: [[semantic_envelope_sha256, record_sha256]]} ->
        %{semantic_envelope_sha256: semantic_envelope_sha256, record_sha256: record_sha256}

      %{rows: []} ->
        nil
    end
  end
end
