defmodule ServiceRadar.Dgraph.Call do
  @moduledoc """
  Waits for an asynchronous Dgraph NIF call.

  Dgraph NIFs do not block a scheduler. A NIF returns `{:ok, ref, handle}`
  immediately and its native task later sends exactly one
  `{:dgraph_nif_reply, ref, result, {kind, queue_wait_us, elapsed_us}}` to the
  calling process. The native side enforces the call deadline, queue wait
  included. This module is the backstop: it waits for the deadline plus a small
  margin, and if no reply arrived it cancels the native task.

  Cancellation cannot leave a late reply in the caller's mailbox. The native
  task and `cancel` both try to claim the call. If cancel wins, no reply is
  ever sent. If the task already won, the reply is on its way and is collected
  here before returning.

  `kind` is `:ok`, `:timeout`, `:transient` (unreachable cluster, transport
  failure, aborted transaction), `:error` or `:panic`. Only `:timeout` and
  `:transient` are retried, and only when the caller says the operation is
  idempotent. The backoff is jittered. When the last attempt fails, its
  `{:error, reason}` is returned to the caller, never dropped.

  Telemetry:

    * `[:serviceradar, :dgraph, :call, :stop]`: one per attempt that got a
      reply. Measurements: `:duration` and `:queue_wait` (native time units).
      Metadata: `:operation`, `:attempt`, `:kind`.
    * `[:serviceradar, :dgraph, :call, :timeout]`: the backstop fired and the
      call was cancelled. Measurements: `:duration`. Metadata: `:operation`,
      `:attempt`.
    * `[:serviceradar, :dgraph, :call, :retry]`: a retry is about to start.
      Measurements: `:backoff_ms`. Metadata: `:operation`, `:attempt` (the
      attempt that failed), `:kind`.
  """

  @reply :dgraph_nif_reply
  @collect_replying_ms 5_000

  @retryable [:timeout, :transient]

  @type submission :: {:ok, reference(), reference()} | {:error, term()}

  @doc """
  Submit and wait, retrying when `retry?: true`.

  `submit` receives the per-attempt deadline in milliseconds and calls the NIF.
  Options: `:deadline_ms` and `:cancel` (both required), `:retry?`,
  `:max_attempts`, `:reply_margin_ms`, `:retry_base_ms`, `:retry_max_ms`.
  """
  @spec run(atom(), (non_neg_integer() -> submission()), keyword()) :: term()
  def run(operation, submit, opts) when is_atom(operation) and is_function(submit, 1) do
    max_attempts =
      if Keyword.get(opts, :retry?, false),
        do: max(Keyword.get(opts, :max_attempts, 3), 1),
        else: 1

    attempt(operation, submit, opts, 1, max_attempts)
  end

  defp attempt(operation, submit, opts, attempt, max_attempts) do
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)
    margin_ms = Keyword.get(opts, :reply_margin_ms, 2_000)
    cancel = Keyword.fetch!(opts, :cancel)

    {result, kind} =
      case submit.(deadline_ms) do
        {:ok, ref, handle} when is_reference(ref) ->
          await(operation, ref, handle, cancel, deadline_ms + margin_ms, attempt)

        {:error, _reason} = rejected ->
          {rejected, :rejected}
      end

    if kind in @retryable and attempt < max_attempts do
      backoff_ms = backoff_ms(attempt, opts)

      :telemetry.execute(
        [:serviceradar, :dgraph, :call, :retry],
        %{backoff_ms: backoff_ms},
        %{operation: operation, attempt: attempt, kind: kind}
      )

      Process.sleep(backoff_ms)
      attempt(operation, submit, opts, attempt + 1, max_attempts)
    else
      result
    end
  end

  @doc """
  Wait up to `timeout_ms` for the reply to `ref`, cancelling through `cancel`
  when none arrives. Returns `{result, kind}`.
  """
  @spec await(
          atom(),
          reference(),
          term(),
          (term() -> :cancelled | :replying),
          non_neg_integer(),
          pos_integer()
        ) ::
          {term(), atom()}
  def await(operation, ref, handle, cancel, timeout_ms, attempt \\ 1) do
    started = System.monotonic_time()

    receive do
      {@reply, ^ref, result, stats} -> replied(operation, attempt, result, stats)
    after
      timeout_ms ->
        case cancel.(handle) do
          :cancelled ->
            :telemetry.execute(
              [:serviceradar, :dgraph, :call, :timeout],
              %{duration: System.monotonic_time() - started},
              %{operation: operation, attempt: attempt}
            )

            {{:error,
              "dgraph #{operation} got no reply within #{timeout_ms}ms and was cancelled"},
             :timeout}

          :replying ->
            collect_replying(operation, ref, attempt)
        end
    end
  end

  # The native task claimed the reply before cancel could: it is in flight.
  defp collect_replying(operation, ref, attempt) do
    receive do
      {@reply, ^ref, result, stats} -> replied(operation, attempt, result, stats)
    after
      @collect_replying_ms ->
        {{:error, "dgraph #{operation} reply was claimed but not delivered"}, :error}
    end
  end

  defp replied(operation, attempt, result, {kind, queue_wait_us, elapsed_us}) do
    :telemetry.execute(
      [:serviceradar, :dgraph, :call, :stop],
      %{
        duration: System.convert_time_unit(elapsed_us, :microsecond, :native),
        queue_wait: System.convert_time_unit(queue_wait_us, :microsecond, :native)
      },
      %{operation: operation, attempt: attempt, kind: kind}
    )

    {result, kind}
  end

  defp backoff_ms(attempt, opts) do
    base = Keyword.get(opts, :retry_base_ms, 200)
    cap = Keyword.get(opts, :retry_max_ms, 2_000)
    ceiling = min(cap, base * Integer.pow(2, attempt - 1))
    # Full jitter, so callers that failed together do not retry together.
    :rand.uniform(max(ceiling, 1))
  end
end
