defmodule ServiceRadar.Notifications.Validations.ProviderTransportContract do
  @moduledoc """
  Enforces the parts of the provider transport contract (design D2) that have no
  database CHECK constraint behind them.

    * `capabilities` MUST contain both `:send` and `:test`. `test/2` is not
      optional in any tier - every provider declares a test action so
      "test-send before saving" works uniformly, and a definition that declares
      `capabilities` without both is rejected. The manifest validator enforces
      this for the `:wasm_plugin` tier only, so the rule lives here where every
      tier passes through it.
    * `supported_routes` MUST name at least one execution route. A provider that
      supports no route can never carry a delivery; the failure would otherwise
      surface at dispatch time as an unroutable channel rather than at save
      time as a bad provider.

  Membership of each element is already enforced by the attribute's `one_of`
  constraint, so this validation only checks the set-level rules.
  """

  use Ash.Resource.Validation

  @required_capabilities [:send, :test]

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_capabilities(pending(changeset, :capabilities)) do
      validate_supported_routes(pending(changeset, :supported_routes))
    end
  end

  # The checks are decisions about the incoming value, not attribute writes, so
  # they report their result directly and the enclosing update stays atomic
  # instead of needing `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  # Resolve the value this action is about to persist.
  #
  # In an atomic update the casted value lives in `changeset.atomics` rather
  # than in `changeset.attributes`, so reading only the attributes would see a
  # stale value. Neither list is ever written from an atomic expression by the
  # actions on this resource, so a pending value is always a literal list.
  #
  # `Ash.Changeset.get_attribute/2` is deliberately NOT used: it falls through
  # to `get_data/2`, which RAISES when the changeset carries
  # `%OriginalDataNotAvailable{}` - exactly the case a bulk atomic update hits.
  # When the field is neither changing nor readable there is nothing to
  # re-check, because the stored value was validated by the action that wrote
  # it.
  defp pending(changeset, field) do
    with :error <- Keyword.fetch(changeset.atomics, field),
         :error <- Ash.Changeset.fetch_change(changeset, field) do
      original(changeset, field)
    else
      {:ok, value} -> value
    end
  end

  defp original(changeset, field) do
    case changeset.data do
      %{^field => value} -> value
      _other -> nil
    end
  end

  defp validate_capabilities(capabilities) when is_list(capabilities) do
    case Enum.reject(@required_capabilities, &(&1 in capabilities)) do
      [] ->
        :ok

      missing ->
        {:error,
         field: :capabilities,
         message:
           "every provider must declare #{format_list(@required_capabilities)}; missing #{format_list(missing)}"}
    end
  end

  defp validate_capabilities(_other), do: :ok

  defp validate_supported_routes([]) do
    {:error,
     field: :supported_routes, message: "a provider must support at least one execution route"}
  end

  defp validate_supported_routes(_other), do: :ok

  defp format_list(values), do: Enum.map_join(values, ", ", &inspect/1)
end
