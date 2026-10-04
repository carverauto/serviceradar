defmodule ServiceRadar.Identity.Validations.HomepagePreference do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.Identity.Homepage

  @impl true
  def validate(changeset, _opts, _context) do
    kind = pending(changeset, :homepage_kind)
    target = pending(changeset, :homepage_target)

    if Homepage.valid_preference?(kind, target) do
      :ok
    else
      {:error, field: :homepage_kind, message: "must be a platform page or a dashboard id"}
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    validate(changeset, opts, context)
  end

  # The action writes arguments through `set_attribute`. Reading the argument
  # sees an explicit nil, which is how a user clears a saved homepage. Falling
  # through to the stored row would treat that clear as "leave the old value".
  defp pending(changeset, field) do
    case Ash.Changeset.fetch_argument(changeset, field) do
      {:ok, value} -> value
      :error -> stored(changeset, field)
    end
  end

  defp stored(changeset, field) do
    with :error <- Keyword.fetch(changeset.atomics || [], field),
         :error <- Ash.Changeset.fetch_change(changeset, field) do
      case changeset.data do
        %{^field => value} -> value
        _other -> nil
      end
    else
      {:ok, value} -> value
    end
  end
end
