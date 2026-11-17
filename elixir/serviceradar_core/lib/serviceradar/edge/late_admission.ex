defmodule ServiceRadar.Edge.LateAdmission do
  @moduledoc """
  Issues the late-admission delivery grants that let a record produced under authority that has
  since lapsed reach the pipeline (openspec add-edge-production-time-admission, design Decisions 3
  and 7). Nothing an agent captured is left stranded: a verified late record always gets a grant,
  PRIMARY or AUDIT, decided from what core retains about the authority live when it was produced.

  The gateway verifies each record's bytes, signatures and origin against the authenticated agent
  before it asks (`ServiceRadarAgentGateway.EdgeDeliveryGrants.late/2`), and passes the record's
  coordinates. Core then judges checks 6 to 9 of Decision 3 with its own clock:

    6. the authority history (`platform.edge_authority_history`) holds an interval for the
       record's `(producer_assignment_id, authority_epoch)` that binds this agent, network scope
       and run shard and covers `produced_at` within the clock tolerance;
    7. that interval did not end `compromised`;
    8. the record is no older than `late_admission_max_age_seconds` and the ledger still covers
       it (`ServiceRadar.Edge.LedgerCoverage`);
    9. its registry epoch is still admitted (not retired).

  All pass: PRIMARY with reason `admitted`. Otherwise AUDIT with the failing check's reason:
  `history_unknown` (no interval), `fenced_at_production` (the epoch was not live for this binding
  when the record was produced), `compromise_ended`, `beyond_late_window`, `ledger_pruned` or
  `contract_retired`. Core never refuses a verified record outright. It issues no grant only for a
  record naming an interval that ended `certificate_revoked` or `revoked_cause_unknown`, whoever
  presents it (`:certificate_revoked_interval`: the gateway quarantines it from its trust
  snapshot), and, for now, for a record whose `produced_at` is still in core's future
  (`:not_yet`: it waits in the late generation and is judged once core's clock catches up).

  `produced_at` is the UUIDv7 time of `event_id`, which the record's signed production window
  already binds. A grant is an `EdgeDeliveryClaimsV1` late-admission transition, signed for the
  `delivery` purpose and short-lived like a renewal grant.
  """

  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.LedgerCoverage
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.Edge.RecordTrust
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryLateAdmissionV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.Repo

  @terminal_reasons ["certificate_revoked", "revoked_cause_unknown"]
  @ns_per_ms 1_000_000

  @type item :: %{
          sequence: pos_integer(),
          spool_id: <<_::128>>,
          event_id: <<_::128>>,
          record_sha256: <<_::256>>,
          network_scope_id: <<_::128>>,
          producer_assignment_id: <<_::128>>,
          run_shard: non_neg_integer(),
          authority_epoch: non_neg_integer(),
          registry_epoch: non_neg_integer()
        }

  @type interval :: %{
          agent_id: String.t(),
          network_scope_id: <<_::128>>,
          run_shard: non_neg_integer(),
          active_from: DateTime.t(),
          active_until: DateTime.t() | nil,
          ended_reason: String.t() | nil
        }

  @type context :: %{
          intervals: %{{<<_::128>>, non_neg_integer()} => [interval()]},
          max_age_seconds: pos_integer(),
          complete_since: DateTime.t() | nil,
          admitted_registry_epochs: MapSet.t(pos_integer())
        }

  @type audit_reason ::
          :fenced_at_production
          | :history_unknown
          | :compromise_ended
          | :beyond_late_window
          | :ledger_pruned
          | :contract_retired

  @type decision ::
          {:grant, :primary, :admitted}
          | {:grant, :audit, audit_reason()}
          | {:refuse, :not_yet | :certificate_revoked_interval}

  @type result :: %{
          sequence: pos_integer(),
          delivery_capability: EdgeSignedCapabilityV1.t() | nil,
          refusal: atom() | nil
        }

  @doc "The most records one call may name: the renewal bound."
  @spec max_items() :: pos_integer()
  def max_items, do: DeliveryGrants.max_items()

  @doc """
  Issues a grant, or a refusal, for each item, in order. `opts` are for tests: `:key` (default the
  configured issuer key), `:registry` (default its verified registry view) and `:now`. An error
  when history, settings, coverage or the registry cannot be read, and `{:error, :too_many_items}`
  past `max_items/0`.
  """
  @spec issue(String.t(), [item()], keyword()) :: {:ok, [result()]} | {:error, term()}
  def issue(agent_id, items, opts \\ []) when is_binary(agent_id) and is_list(items) do
    if length(items) > max_items() do
      {:error, :too_many_items}
    else
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      with {:ok, key} <- option(opts, :key, &IssuerKey.configured/0),
           {:ok, registry} <- option(opts, :registry, &ContractRegistry.view/0),
           {:ok, context} <- context(items, registry) do
        {:ok, Enum.map(items, &result(&1, agent_id, context, key, now))}
      end
    end
  end

  defp option(opts, name, default) do
    case Keyword.fetch(opts, name) do
      {:ok, value} -> {:ok, value}
      :error -> default.()
    end
  end

  defp result(item, agent_id, context, key, now) do
    case decide(item, agent_id, context, now) do
      {:refuse, reason} ->
        %{sequence: item.sequence, delivery_capability: nil, refusal: reason}

      {:grant, _publication, _reason} = decision ->
        %{
          sequence: item.sequence,
          delivery_capability: grant(item, decision, key, now),
          refusal: nil
        }
    end
  end

  @doc """
  Core's decision for one late record (Decision 3, checks 6 to 9), with `context` read from the
  database (`issue/3`). Pure: the same inputs always decide the same way.
  """
  @spec decide(item(), String.t(), context(), DateTime.t()) :: decision()
  def decide(item, agent_id, context, %DateTime{} = now) do
    produced_at = produced_at(item.event_id)
    tolerance = RecordTrust.clock_tolerance_nano()

    intervals =
      Map.get(context.intervals, {item.producer_assignment_id, item.authority_epoch}, [])

    cond do
      DateTime.to_unix(produced_at, :nanosecond) - tolerance > DateTime.to_unix(now, :nanosecond) ->
        {:refuse, :not_yet}

      Enum.any?(intervals, &(&1.ended_reason in @terminal_reasons)) ->
        {:refuse, :certificate_revoked_interval}

      true ->
        case history(item, agent_id, intervals, produced_at, tolerance) do
          :live -> bounds(item, context, produced_at, now)
          reason -> {:grant, :audit, reason}
        end
    end
  end

  # Checks 6 and 7: an interval of the named epoch that binds this agent's record and was live
  # (within the tolerance) when it was produced.
  defp history(_item, _agent_id, [], _produced_at, _tolerance), do: :history_unknown

  defp history(item, agent_id, intervals, produced_at, tolerance) do
    live =
      Enum.filter(intervals, fn interval ->
        binds?(interval, item, agent_id) and covers?(interval, produced_at, tolerance)
      end)

    cond do
      live == [] -> :fenced_at_production
      Enum.any?(live, &(&1.ended_reason == "compromised")) -> :compromise_ended
      true -> :live
    end
  end

  defp binds?(interval, item, agent_id) do
    interval.agent_id == agent_id and interval.network_scope_id == item.network_scope_id and
      interval.run_shard == item.run_shard
  end

  defp covers?(interval, produced_at, tolerance) do
    from = DateTime.add(interval.active_from, -tolerance, :nanosecond)

    not DateTime.before?(produced_at, from) and
      (is_nil(interval.active_until) or
         DateTime.before?(
           produced_at,
           DateTime.add(interval.active_until, tolerance, :nanosecond)
         ))
  end

  # Checks 8 and 9: the late window, ledger coverage and an admitted registry epoch.
  defp bounds(item, context, produced_at, now) do
    cond do
      DateTime.diff(now, produced_at, :second) > context.max_age_seconds ->
        {:grant, :audit, :beyond_late_window}

      not LedgerCoverage.primary_eligible?(produced_at, context.complete_since) ->
        {:grant, :audit, :ledger_pruned}

      not MapSet.member?(context.admitted_registry_epochs, item.registry_epoch) ->
        {:grant, :audit, :contract_retired}

      true ->
        {:grant, :primary, :admitted}
    end
  end

  @doc "The signed late-admission delivery grant carrying `decision` for `item`."
  @spec grant(item(), decision(), IssuerKey.t(), DateTime.t()) :: EdgeSignedCapabilityV1.t()
  def grant(item, {:grant, publication, reason}, %IssuerKey{} = key, %DateTime{} = now) do
    not_before = DateTime.to_unix(now, :nanosecond)
    expires = not_before + DeliveryGrants.ttl_seconds() * 1_000_000_000

    claims = %EdgeDeliveryClaimsV1{
      event_id: item.event_id,
      record_sha256: item.record_sha256,
      spool_id: item.spool_id,
      sequence: item.sequence,
      transition:
        {:late_admission,
         %EdgeDeliveryLateAdmissionV1{
           produced_at_unix_nano: DateTime.to_unix(produced_at(item.event_id), :nanosecond),
           authority_epoch: item.authority_epoch,
           publication: publication(publication),
           reason: reason(reason)
         }}
    }

    IssuerKey.sign(
      %EdgeSignedCapabilityV1{
        not_before_unix_nano: not_before,
        expires_at_unix_nano: expires,
        claims: {:delivery, claims}
      },
      key
    )
  end

  defp publication(:primary), do: :EDGE_LATE_PUBLICATION_PRIMARY
  defp publication(:audit), do: :EDGE_LATE_PUBLICATION_AUDIT

  defp reason(:admitted), do: :EDGE_LATE_DECISION_REASON_ADMITTED
  defp reason(:fenced_at_production), do: :EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION
  defp reason(:history_unknown), do: :EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN
  defp reason(:compromise_ended), do: :EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED
  defp reason(:beyond_late_window), do: :EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW
  defp reason(:ledger_pruned), do: :EDGE_LATE_DECISION_REASON_LEDGER_PRUNED
  defp reason(:contract_retired), do: :EDGE_LATE_DECISION_REASON_CONTRACT_RETIRED

  # The UUIDv7 time of the event id: whole milliseconds, as the producer minted it.
  defp produced_at(<<millis::48, _::80>>) do
    DateTime.truncate(DateTime.from_unix!(millis * @ns_per_ms, :nanosecond), :microsecond)
  end

  # --- reading ---------------------------------------------------------------------------

  defp context(items, registry) do
    with {:ok, intervals} <- read_intervals(items),
         {:ok, max_age_seconds} <- PipelineSettings.late_admission_max_age_seconds(),
         {:ok, complete_since} <- LedgerCoverage.complete_since() do
      {:ok,
       %{
         intervals: intervals,
         max_age_seconds: max_age_seconds,
         complete_since: complete_since,
         admitted_registry_epochs: MapSet.new(registry.epochs, & &1.epoch)
       }}
    end
  end

  defp read_intervals([]), do: {:ok, %{}}

  defp read_intervals(items) do
    keys = Enum.uniq_by(items, &{&1.producer_assignment_id, &1.authority_epoch})

    case Repo.query(
           """
           SELECT h.assignment_id, h.authority_epoch, h.agent_id, h.network_scope_id,
                  h.run_shard, h.active_from, h.active_until, h.ended_reason
             FROM platform.edge_authority_history AS h
             JOIN unnest($1::uuid[], $2::bigint[]) AS k(assignment_id, authority_epoch)
               ON h.assignment_id = k.assignment_id AND h.authority_epoch = k.authority_epoch
           """,
           [Enum.map(keys, & &1.producer_assignment_id), Enum.map(keys, & &1.authority_epoch)]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.group_by(rows, &interval_key/1, &interval/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interval_key([assignment_id, epoch | _]), do: {assignment_id, epoch}

  defp interval([_assignment, _epoch, agent_id, scope, shard, from, until, reason]) do
    %{
      agent_id: agent_id,
      network_scope_id: scope,
      run_shard: shard,
      active_from: from,
      active_until: until,
      ended_reason: reason
    }
  end
end
