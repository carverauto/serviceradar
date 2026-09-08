defmodule ServiceRadar.Integrations.Validations.CompositeExport do
  @moduledoc """
  Validates `settings["composite"]`, the northbound composite check selection.

  The three values are ONE selection, not three independent settings:
  `ArmisNorthboundRunner.composite_export/1` requires all of them and reads a
  half-configured export as "not configured". Without this validation an
  operator can save two of the three and get silence — no export, no error, and
  nothing on the page saying why.

  `value_form` is checked against the exact vocabulary the runner accepts.
  It maps only `"verdict"` and `"status"`; anything else disables the export
  there, so accepting it here would store a value that reads as unconfigured.

  This deliberately does NOT reject a check that is merely absent or not
  enabled. `CompositeNorthboundValues.for_devices/3` requires an enabled check,
  but a slug can legitimately point at a check that is still a draft — the
  operator is configuring the export before flipping the check live, and the
  picker labels that state. Rejecting it would make "configure now, enable
  later" impossible; the export simply publishes nothing until then.
  """

  use Ash.Resource.Validation

  @value_forms ~w(verdict status)

  # Delegate rather than returning a bare `:ok`: a validation whose `atomic/3`
  # returns `:ok` is skipped when the action runs atomically, which would let a
  # half-configured composite export through on update.
  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :settings) do
      changeset
      |> Ash.Changeset.get_attribute(:settings)
      |> check()
    else
      :ok
    end
  end

  @doc """
  The rule itself, over a plain settings map.

  Split out from `validate/3` so it can be tested without a changeset, and
  therefore without Ash's consolidated protocols, the Repo, or a database --
  this is the whole content of the validation, and hiding it behind changeset
  plumbing would put it in the `:requires_app` tier where it needs the shared
  fixture to run at all.
  """
  @spec check(term()) :: :ok | {:error, keyword()}
  def check(settings) do
    settings
    |> composite()
    |> validate_composite()
  end

  defp composite(settings) when is_map(settings), do: Map.get(settings, "composite")
  defp composite(_settings), do: nil

  defp validate_composite(nil), do: :ok

  defp validate_composite(composite) when not is_map(composite) do
    error("composite export settings must be a map")
  end

  defp validate_composite(composite) do
    slug = trimmed(composite, "check_slug")
    form = trimmed(composite, "value_form")
    field = trimmed(composite, "custom_field")

    cond do
      # Absent entirely is how the export is turned off. The form deletes the
      # key rather than writing blanks, but a direct API write may not.
      slug == nil and form == nil and field == nil ->
        :ok

      slug == nil ->
        error("composite export requires check_slug")

      field == nil ->
        error("composite export requires custom_field")

      form not in @value_forms ->
        error("composite export value_form must be one of: #{Enum.join(@value_forms, ", ")}")

      true ->
        :ok
    end
  end

  defp trimmed(composite, key) do
    case Map.get(composite, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp error(message), do: {:error, field: :settings, message: message}
end
