defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Lease do
  @moduledoc false

  # `fence_current/3` is the durable counterpart to the local `claimable?/3`
  # fast path below. It locks the request row inside the executor's existing
  # materialization transaction and proves the caller still owns a live lease
  # before any assignment or grant is changed.

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Repo

  require Ash.Query

  @actor SystemActor.system(:plugin_policy_assignment_recovery_executor)

  # This is deliberately only a local fast-path. `claim_current/5` is the
  # concurrency authority: its single conditional UPDATE prevents two
  # executors from owning one request after a race.
  @terminal_statuses [
    :reconciled,
    :no_longer_eligible,
    :owner_not_authoritative,
    :identity_unavailable,
    :identity_changed,
    :package_unapproved,
    :schema_invalid,
    :conflict,
    :denied,
    :failed
  ]

  @spec claimable?(atom() | String.t() | nil, DateTime.t() | nil, DateTime.t()) :: boolean()
  def claimable?(:requested, _lease_expires_at, %DateTime{}), do: true

  def claimable?(:executing, %DateTime{} = lease_expires_at, %DateTime{} = now) do
    DateTime.compare(lease_expires_at, now) != :gt
  end

  def claimable?(_status, _lease_expires_at, _now), do: false

  @doc false
  @spec fence_current(String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :recovery_lease_lost | :recovery_lease_fence_unavailable}
  def fence_current(request_id, lease_token, %DateTime{} = now)
      when is_binary(request_id) and is_binary(lease_token) do
    # PostgreSQL re-evaluates this predicate after waiting for a concurrent
    # row writer. Once selected, `FOR UPDATE` keeps the exact request row
    # locked until the surrounding Repo.transaction commits or rolls back.
    # That makes the token and expiration a true write fence, rather than a
    # stale preflight observation.
    PluginPolicyAssignmentRecoveryRequest
    |> Ash.Query.for_read(:by_id, %{id: request_id})
    |> Ash.Query.filter(
      id == ^request_id and status == :executing and lease_token == ^lease_token and
        lease_expires_at > ^now
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %PluginPolicyAssignmentRecoveryRequest{}} -> :ok
      {:ok, nil} -> {:error, :recovery_lease_lost}
      {:error, _reason} -> {:error, :recovery_lease_fence_unavailable}
    end
  end

  def fence_current(_request_id, _lease_token, _now), do: {:error, :recovery_lease_lost}

  @doc false
  @spec claim_current(String.t(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          :ok | {:error, term()}
  def claim_current(request_id, lease_token, now, lease_expires_at, opts \\ [])

  def claim_current(
        request_id,
        lease_token,
        %DateTime{} = now,
        %DateTime{} = lease_expires_at,
        opts
      )
      when is_binary(request_id) and is_binary(lease_token) and is_list(opts) do
    with :ok <- require_executor(Keyword.get(opts, :actor)),
         {:ok, request_id} <- Ecto.UUID.dump(request_id),
         {:ok, lease_token} <- Ecto.UUID.dump(lease_token),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE platform.plugin_policy_assignment_recovery_requests
             SET status = 'executing',
                 started_at = $3,
                 lease_token = $2,
                 lease_expires_at = $4,
                 updated_at = $3
             WHERE id = $1
               AND (
                 status = 'requested'
                 OR (status = 'executing' AND lease_expires_at <= $3)
               )
             """,
             [request_id, lease_token, now, lease_expires_at]
           ) do
      :ok
    else
      {:error, :recovery_lease_requires_recovery_executor} = error -> error
      :error -> {:error, :invalid_recovery_claim_scope}
      {:ok, %{num_rows: 0}} -> {:error, :recovery_lease_lost}
      {:error, _reason} -> {:error, :recovery_lease_claim_unavailable}
    end
  end

  def claim_current(_request_id, _lease_token, _now, _lease_expires_at, _opts),
    do: {:error, :invalid_recovery_claim_scope}

  @doc false
  @spec finish_current(
          String.t(),
          String.t(),
          atom(),
          [String.t()],
          DateTime.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def finish_current(request_id, lease_token, outcome, assignment_ids, now, opts \\ [])

  def finish_current(request_id, lease_token, outcome, assignment_ids, %DateTime{} = now, opts)
      when is_binary(request_id) and is_binary(lease_token) and is_atom(outcome) and
             is_list(assignment_ids) and
             is_list(opts) do
    with :ok <- require_executor(Keyword.get(opts, :actor)),
         true <- outcome in @terminal_statuses || {:error, :invalid_recovery_terminal_status},
         {:ok, request_id} <- Ecto.UUID.dump(request_id),
         {:ok, lease_token} <- Ecto.UUID.dump(lease_token),
         {:ok, assignment_ids} <- dump_uuid_array(assignment_ids),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE platform.plugin_policy_assignment_recovery_requests
             SET status = $3,
                 outcome_code = $4,
                 outcome_details = $5,
                 replacement_assignment_ids = $6,
                 completed_at = $7,
                 lease_token = NULL,
                 lease_expires_at = NULL,
                 updated_at = $7
             WHERE id = $1
               AND status = 'executing'
               AND lease_token = $2
               AND lease_expires_at > $7
             """,
             [
               request_id,
               lease_token,
               Atom.to_string(outcome),
               Atom.to_string(outcome),
               %{"outcome" => Atom.to_string(outcome)},
               assignment_ids,
               now
             ]
           ) do
      :ok
    else
      {:error, :recovery_lease_requires_recovery_executor} = error -> error
      {:error, :invalid_replacement_assignment_id} = error -> error
      :error -> {:error, :invalid_recovery_finish_scope}
      {:ok, %{num_rows: 0}} -> {:error, :recovery_lease_lost}
      {:error, _reason} -> {:error, :recovery_lease_finish_unavailable}
      false -> {:error, :invalid_recovery_terminal_status}
    end
  end

  def finish_current(_request_id, _lease_token, _outcome, _assignment_ids, _now, _opts),
    do: {:error, :invalid_recovery_finish_scope}

  defp require_executor(actor) when is_map(actor) do
    expected = @actor

    if actor_value(actor, :id) == expected.id and actor_value(actor, :role) == expected.role,
      do: :ok,
      else: {:error, :recovery_lease_requires_recovery_executor}
  end

  defp require_executor(_actor), do: {:error, :recovery_lease_requires_recovery_executor}

  defp dump_uuid_array(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Ecto.UUID.dump(value) do
        {:ok, dumped} -> {:cont, {:ok, [dumped | acc]}}
        :error -> {:halt, {:error, :invalid_replacement_assignment_id}}
      end
    end)
    |> case do
      {:ok, dumped} -> {:ok, Enum.reverse(dumped)}
      error -> error
    end
  end

  defp actor_value(actor, key), do: Map.get(actor, key) || Map.get(actor, Atom.to_string(key))

  @spec terminal?(atom() | String.t() | nil) :: boolean()
  def terminal?(status), do: status in @terminal_statuses
end
