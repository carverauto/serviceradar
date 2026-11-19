defmodule ServiceRadar.Credentials.Changes.ApplyGrantCachePolicy do
  @moduledoc """
  Sets a broker grant's cache policy from its consumer and its secret when the
  grant is issued.

  The issue action does not accept `cache_mode` or `cache_ttl_seconds`, so no
  caller can widen caching. Every issuer gets the same decision from
  `ServiceRadar.Credentials.GrantCachePolicy`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Credentials.GrantCachePolicy

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &apply_policy(&1, context))
  end

  defp apply_policy(changeset, context) do
    scope = %{
      consumer_kind: Ash.Changeset.get_attribute(changeset, :consumer_kind),
      consumer_id: Ash.Changeset.get_attribute(changeset, :consumer_id),
      ttl_seconds: Ash.Changeset.get_attribute(changeset, :ttl_seconds)
    }

    secret =
      changeset
      |> Ash.Changeset.get_attribute(:secret_id)
      |> GrantCachePolicy.load_secret(Ash.Context.to_opts(context))

    Ash.Changeset.force_change_attributes(changeset, GrantCachePolicy.cache_attrs(scope, secret))
  end
end
