defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.FormState do
  @moduledoc """
  Params to form map, and client-side validation for the composite check form.

  Validation here is for immediate feedback only. The resource is the authority:
  scope must target devices, the slug is immutable after creation, and enabling
  requires a liveness witness and vantage point coverage. Those are enforced by
  Ash and are surfaced from the save/enable result rather than re-implemented.
  """

  @default_interval 300

  @doc "A blank form for a new check."
  def default_form do
    %{
      "name" => "",
      "description" => "",
      "scope_query" => "in:devices",
      "evaluation_interval_seconds" => Integer.to_string(@default_interval)
    }
  end

  @doc "The form for an existing check."
  def form_from_check(check) do
    %{
      "name" => check.name || "",
      "description" => check.description || "",
      "scope_query" => check.scope_query || "",
      "evaluation_interval_seconds" => Integer.to_string(check.evaluation_interval_seconds || @default_interval)
    }
  end

  @doc "Coerces raw form params into the shape the rest of the LiveView expects."
  def normalize_form(params) when is_map(params) do
    Map.merge(default_form(), stringify(params))
  end

  def normalize_form(_params), do: default_form()

  @doc """
  Attributes for the Ash create/update action.

  `evaluation_interval_seconds` is cast here rather than in the resource so a
  non-numeric entry becomes a form error instead of an Ash cast failure.
  """
  def to_attrs(form) do
    %{
      name: String.trim(form["name"] || ""),
      description: blank_to_nil(form["description"]),
      scope_query: String.trim(form["scope_query"] || ""),
      evaluation_interval_seconds: parse_interval(form["evaluation_interval_seconds"])
    }
  end

  @doc "Returns `[{field, message}]` for anything the form can catch locally."
  def validate(form) do
    []
    |> validate_present(form, "name", "Name is required")
    |> validate_present(form, "scope_query", "Scope query is required")
    |> validate_interval(form)
    |> Enum.reverse()
  end

  defp validate_present(errors, form, field, message) do
    if String.trim(form[field] || "") == "" do
      [{field, message} | errors]
    else
      errors
    end
  end

  defp validate_interval(errors, form) do
    case parse_interval(form["evaluation_interval_seconds"]) do
      nil ->
        [{"evaluation_interval_seconds", "Interval must be a whole number of seconds"} | errors]

      seconds when seconds < 60 ->
        [{"evaluation_interval_seconds", "Interval must be at least 60 seconds"} | errors]

      seconds when seconds > 86_400 ->
        [{"evaluation_interval_seconds", "Interval must be at most 86400 seconds (24h)"} | errors]

      _seconds ->
        errors
    end
  end

  def parse_interval(value) do
    case Integer.parse(String.trim(to_string(value || ""))) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(_params), do: %{}

  @doc "Human-readable message for an Ash error returned by save or enable."
  def error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    Enum.map_join(errors, "; ", fn error ->
      case error do
        %{message: message} when is_binary(message) -> message
        other -> inspect(other)
      end
    end)
  end

  def error_message(error) when is_exception(error), do: Exception.message(error)
  def error_message(other), do: inspect(other)
end
