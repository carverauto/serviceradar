defmodule ServiceRadar.Edge.Projector do
  @moduledoc """
  The behaviour an output contract's projector implements. `ServiceRadar.Edge.ContractCatalog`
  maps each contract to its projector, and `ServiceRadar.EventWriter.Processors.EdgeRecord`
  drives it, so adding a contract never adds a clause to the processor.

    * `decode/1` validates the record's payload and returns the decoded body. A refusal is an
      `{:error, reason}`; the record is then dead-lettered without projecting.
    * `publish/3` (optional) performs a side effect outside the database, such as a republish
      to an existing JetStream subject. It runs before the ledger transaction, only for a fresh
      primary delivery. `{:settled, reason}` commits the ledger without domain writes and records
      `:settled`; `{:refused, reason}` refuses the record; `{:error, reason}` fails the batch so
      JetStream redelivers it.
    * `project/4` (optional) writes domain state inside the ledger transaction. `primary?` is
      true only for a fresh delivery that is not late-fenced. `{:settled, reason}` commits the
      ledger and records `:settled`. `{:refused, reason}` rolls the transaction back and
      dead-letters on first delivery. An `{:error, reason}` rolls the transaction back: a
      `reason` that is an atom or a tuple tagged with one refuses the record, whereas an
      exception or Ash changeset (a failed write) is redelivered.
      `{:defer, :pending | :blocked}` commits the ledger and domain writes, then keeps the
      delivery retryable. A projector using defer must revisit its durable state on ledger
      replay. `late_fenced?` distinguishes a non-authoritative delivery from a replay.
    * `committed/3` (optional) runs after the ledger transaction commits for a fresh primary
      delivery, so commit-gated telemetry and staged-artifact cleanup run only when the ledger
      row is durable.
  """

  alias Serviceradar.Edge.V1.EdgeRecordV1

  @type reason_ref :: atom() | {atom(), term()}

  @type context :: %{
          required(:ledger) => :inserted | :replay,
          required(:primary?) => boolean(),
          required(:late_fenced?) => boolean(),
          required(:gateway_id) => String.t() | nil,
          optional(:projection) => :projected | :settled,
          optional(:projector_opts) => keyword()
        }

  @callback decode(EdgeRecordV1.t()) :: {:ok, term()} | {:error, term()}
  @callback publish(EdgeRecordV1.t(), term(), keyword()) ::
              :ok | {:settled, reason_ref()} | {:refused, reason_ref()} | {:error, term()}
  @callback project(module(), EdgeRecordV1.t(), term(), context()) ::
              :ok
              | {:settled, reason_ref()}
              | {:defer, :pending | :blocked}
              | {:refused, reason_ref()}
              | {:error, term()}
  @callback committed(EdgeRecordV1.t(), term(), context()) :: :ok

  @optional_callbacks publish: 3, project: 4, committed: 3
end
