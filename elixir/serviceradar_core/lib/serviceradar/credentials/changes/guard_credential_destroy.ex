defmodule ServiceRadar.Credentials.Changes.GuardCredentialDestroy do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidChanges
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialUsage
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit

  require Ash.Query

  @system_actor SystemActor.system(:credential_secret_delete)
  @live_grant_statuses [:issued, :active]

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&guard_and_prepare(&1, context))
    |> Ash.Changeset.after_action(&record_redacted_audit/2)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "credential deletion requires locked usage rechecks"}

  defp guard_and_prepare(changeset, context) do
    actor = caller_actor(changeset, context)
    confirmed_id = Ash.Changeset.get_argument(changeset, :confirm_secret_id)

    with :ok <- confirm_id(confirmed_id, changeset.data.id),
         {:ok, secret} <- lock_fresh_secret(changeset.data.id, actor, context),
         now = DateTime.utc_now(),
         {:ok, grants} <- lock_grants(secret.id, context),
         {:ok, %Result{} = usage} <- CredentialUsage.for_secret(secret.id, actor: actor, now: now),
         :ok <- reject_live_usage(usage),
         :ok <- validate_prunable_grants(grants, now),
         :ok <- prune_grants(grants, now, context) do
      changeset
      |> Map.put(:data, secret)
      |> Ash.Changeset.put_context(:credential_deletion_audit, audit_attrs(secret, actor, now))
    else
      {:error, :confirmation_mismatch} ->
        invalid(changeset, :confirm_secret_id, "credential_confirmation_mismatch")

      {:error, :credential_in_use} ->
        invalid(changeset, :id, "credential_in_use")

      {:error, {:credential_usage_unavailable, _source}} ->
        invalid(changeset, :id, "credential_usage_unavailable")

      {:error, :grant_not_prunable} ->
        invalid(changeset, :id, "credential_in_use")

      {:error, :grant_cleanup_failed} ->
        invalid(changeset, :id, "credential_grant_cleanup_failed")

      {:error, :secret_unavailable} ->
        invalid(changeset, :id, "credential_delete_unavailable")
    end
  rescue
    _error -> invalid(changeset, :id, "credential_delete_unavailable")
  catch
    _kind, _reason -> invalid(changeset, :id, "credential_delete_unavailable")
  end

  defp confirm_id(id, id), do: :ok
  defp confirm_id(_confirmed_id, _secret_id), do: {:error, :confirmation_mismatch}

  defp lock_fresh_secret(secret_id, actor, context) do
    opts = caller_opts(actor, context)

    result =
      NetworkCredentialSecret
      |> Ash.Query.for_read(:by_id, %{id: secret_id}, opts)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(opts)

    case result do
      {:ok, %NetworkCredentialSecret{} = secret} -> {:ok, secret}
      {:ok, nil} -> {:error, :secret_unavailable}
      {:error, _error} -> {:error, :secret_unavailable}
    end
  end

  defp lock_grants(secret_id, context) do
    opts = system_opts(context)

    result =
      CredentialBrokerGrant
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(secret_id == ^secret_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ash.read(opts)

    case result do
      {:ok, grants} when is_list(grants) -> {:ok, grants}
      {:error, _error} -> {:error, {:credential_usage_unavailable, :credential_broker_grants}}
    end
  end

  defp reject_live_usage(%Result{consumers: [], live_grants: []}), do: :ok
  defp reject_live_usage(%Result{}), do: {:error, :credential_in_use}

  defp validate_prunable_grants(grants, now) do
    if Enum.all?(grants, &prunable?(&1, now)) do
      :ok
    else
      {:error, :grant_not_prunable}
    end
  end

  defp prunable?(%CredentialBrokerGrant{status: status}, _now)
       when status not in @live_grant_statuses, do: true

  defp prunable?(
         %CredentialBrokerGrant{status: status, expires_at: %DateTime{} = expires_at},
         now
       )
       when status in @live_grant_statuses, do: DateTime.compare(expires_at, now) != :gt

  defp prunable?(_grant, _now), do: false

  defp prune_grants(grants, now, context) do
    Enum.reduce_while(grants, :ok, fn grant, :ok ->
      changeset =
        Ash.Changeset.for_destroy(
          grant,
          :prune_for_secret_deletion,
          %{cutoff: now},
          system_opts(context)
        )

      case Ash.destroy(changeset, system_opts(context)) do
        :ok -> {:cont, :ok}
        {:ok, _destroyed} -> {:cont, :ok}
        {:error, _error} -> {:halt, {:error, :grant_cleanup_failed}}
      end
    end)
  end

  defp audit_attrs(secret, actor, deleted_at) do
    %{
      secret_id: secret.id,
      name: secret.name,
      provider: secret.provider,
      credential_kind: secret.credential_kind,
      source_type: secret.source_type,
      deleted_by_actor_id: actor_id(actor),
      deleted_at: deleted_at
    }
  end

  defp record_redacted_audit(changeset, destroyed_secret) do
    attrs = Map.fetch!(changeset.context, :credential_deletion_audit)

    case create_redacted_audit(attrs) do
      {:ok, _audit} ->
        {:ok, destroyed_secret}

      {:error, :audit_failed} ->
        {:error,
         InvalidChanges.exception(
           fields: [:id],
           message: "credential_deletion_audit_failed"
         )}
    end
  end

  defp create_redacted_audit(attrs) do
    NetworkCredentialSecretDeletionAudit
    |> Ash.Changeset.for_create(:record, attrs, actor: @system_actor)
    |> Ash.create(actor: @system_actor)
    |> case do
      {:ok, audit} -> {:ok, audit}
      {:error, _error} -> {:error, :audit_failed}
    end
  rescue
    _error -> {:error, :audit_failed}
  catch
    _kind, _reason -> {:error, :audit_failed}
  end

  defp caller_actor(changeset, context) do
    get_in(changeset.context, [:private, :actor]) || context.actor
  end

  defp caller_opts(actor, context) do
    Enum.reject([actor: actor, tenant: context.tenant, tracer: context.tracer], fn {_key, value} ->
      is_nil(value)
    end)
  end

  defp system_opts(context) do
    Enum.reject([actor: @system_actor, tenant: context.tenant, tracer: context.tracer], fn {_key,
                                                                                            value} ->
      is_nil(value)
    end)
  end

  defp actor_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_id(%{user: %{id: id}}) when not is_nil(id), do: to_string(id)
  defp actor_id(_actor), do: nil

  defp invalid(changeset, field, message) do
    Ash.Changeset.add_error(changeset, field: field, message: message)
  end
end
