defmodule ServiceRadar.Credentials.Changes.GuardCredentialRuleLifecycle do
  @moduledoc """
  Serializes rule deletion with every rule-bound broker grant issuance.

  Both actions lock the same rule row inside their Ash transaction. A caller
  holding a previously resolved rule cannot issue a grant after it is disabled
  or removed. Terminal grants retain their historical rule UUID after deletion.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule

  require Ash.Query

  @impl true
  def change(changeset, opts, context) do
    mode = Keyword.fetch!(opts, :mode)
    Ash.Changeset.before_action(changeset, &guard(&1, context, mode))
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "credential rule lifecycle requires a locked current-rule check"}

  defp guard(changeset, context, :issue) do
    case Ash.Changeset.get_attribute(changeset, :credential_rule_id) do
      nil ->
        changeset

      id ->
        with {:ok, rule} <- lock_rule(id, context),
             :ok <- require_enabled(rule),
             :ok <- require_current_secret(rule, Ash.Changeset.get_attribute(changeset, :secret_id)) do
          changeset
        else
          {:error, reason} -> invalid(changeset, :credential_rule_id, reason)
        end
    end
  end

  defp guard(changeset, context, :destroy) do
    with {:ok, rule} <- lock_rule(changeset.data.id, context),
         :ok <- require_disabled(rule),
         :ok <- require_no_live_grants(rule.id, context) do
      %{changeset | data: rule}
    else
      {:error, reason} -> invalid(changeset, :id, reason)
    end
  end

  defp lock_rule(id, context) do
    opts = caller_opts(context)

    result =
      NetworkCredentialRule
      |> Ash.Query.for_read(:by_id, %{id: id}, opts)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(opts)

    case result do
      {:ok, %NetworkCredentialRule{} = rule} -> {:ok, rule}
      _ -> {:error, :credential_rule_unavailable}
    end
  end

  defp require_enabled(%{enabled: true}), do: :ok
  defp require_enabled(_rule), do: {:error, :credential_rule_disabled}
  defp require_disabled(%{enabled: false}), do: :ok
  defp require_disabled(_rule), do: {:error, :credential_rule_must_be_disabled}

  defp require_current_secret(%{secret_id: id}, id), do: :ok
  defp require_current_secret(_rule, _secret_id), do: {:error, :credential_rule_secret_changed}

  defp require_no_live_grants(id, context) do
    opts = caller_opts(context)
    now = DateTime.utc_now()

    query =
      CredentialBrokerGrant
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(credential_rule_id == ^id and status in [:issued, :active] and expires_at > ^now)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    case Ash.read(query, opts) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :credential_rule_in_use}
      {:error, _error} -> {:error, :credential_rule_usage_unavailable}
    end
  end

  defp caller_opts(context) do
    Enum.reject([actor: context.actor, tenant: context.tenant, tracer: context.tracer], fn {_key, value} ->
      is_nil(value)
    end)
  end

  defp invalid(changeset, field, reason),
    do: Ash.Changeset.add_error(changeset, field: field, message: Atom.to_string(reason))
end
