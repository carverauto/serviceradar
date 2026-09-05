defmodule ServiceRadar.Identity.PrivilegeMutationEffects do
  @moduledoc """
  Owns privileged identity transactions and their post-commit effects.

  Callers return the committed value together with affected user IDs and audit
  options. Cache invalidation and audit delivery happen only after commit. Audit
  delivery is best effort: a failure is logged and never changes a successful
  mutation result.
  """

  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Repo

  require Logger

  @type tx_result(result) ::
          {:ok, result, [String.t()], keyword()} | {:error, term()}

  @spec run(map(), String.t() | [String.t()], (map() -> tx_result(result)), keyword()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def run(scope_or_actor, permissions, tx_fun, opts \\ [])

  def run(scope_or_actor, permissions, tx_fun, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_run(scope_or_actor, permissions, tx_fun, opts)
    end
  end

  @doc false
  @spec run_system(map(), (map() -> tx_result(result)), keyword()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def run_system(system_actor, tx_fun, opts \\ [])

  def run_system(system_actor, tx_fun, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_run_system(system_actor, tx_fun, opts)
    end
  end

  defp do_run(scope_or_actor, permissions, tx_fun, opts)
       when is_function(tx_fun, 1) and is_list(opts) do
    with {:ok, authority} <- CurrentUserAuthority.authorize(scope_or_actor, permissions),
         {:ok, {result, user_ids, audit_opts}} <- owned_transaction(authority.user, tx_fun) do
      post_commit(user_ids, audit_opts, opts)
      {:ok, result}
    end
  end

  defp do_run(_scope_or_actor, _permissions, _tx_fun, _opts), do: {:error, :invalid_boundary_call}

  defp do_run_system(%{role: :system} = system_actor, tx_fun, opts)
       when is_function(tx_fun, 1) and is_list(opts) do
    with {:ok, {result, user_ids, audit_opts}} <- owned_transaction(system_actor, tx_fun) do
      post_commit(user_ids, audit_opts, opts)
      {:ok, result}
    end
  end

  defp do_run_system(_actor, _tx_fun, _opts), do: {:error, :trusted_system_actor_required}

  defp owned_transaction(actor, tx_fun) do
    Repo.transaction(fn ->
      case tx_fun.(actor) do
        {:ok, result, user_ids, audit_opts}
        when is_list(user_ids) and is_list(audit_opts) ->
          {result, user_ids, audit_opts}

        {:error, reason} ->
          Repo.rollback(reason)

        other ->
          Repo.rollback({:invalid_transaction_result, other})
      end
    end)
  end

  defp post_commit(user_ids, audit_opts, opts) do
    user_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.each(&safe_invalidate(&1, opts))

    if audit_opts != [], do: safe_audit(audit_opts, opts)
  end

  defp safe_invalidate(user_id, opts) do
    case invoke(Keyword.get(opts, :cache_invalidator, &RBAC.invalidate_user_cache/1), user_id) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> Logger.warning("RBAC cache invalidation failed: #{inspect(reason)}")
      other -> Logger.warning("RBAC cache invalidation returned: #{inspect(other)}")
    end
  rescue
    error -> Logger.warning("RBAC cache invalidation raised: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("RBAC cache invalidation #{kind}: #{inspect(reason)}")
  end

  defp safe_audit(audit_opts, opts) do
    case invoke(Keyword.get(opts, :audit_writer, AuditWriter), audit_opts) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> Logger.warning("Privilege mutation audit failed: #{inspect(reason)}")
      other -> Logger.warning("Privilege mutation audit returned: #{inspect(other)}")
    end
  rescue
    error -> Logger.warning("Privilege mutation audit raised: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("Privilege mutation audit #{kind}: #{inspect(reason)}")
  end

  defp invoke(fun, value) when is_function(fun, 1), do: fun.(value)
  defp invoke(module, value) when is_atom(module), do: module.write_async(value)
end
