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
      "evaluation_interval_seconds" => Integer.to_string(@default_interval),
      "write_canonical_availability" => "false"
    }
  end

  @doc "The form for an existing check."
  def form_from_check(check) do
    %{
      "name" => check.name || "",
      "description" => check.description || "",
      "scope_query" => check.scope_query || "",
      "evaluation_interval_seconds" => Integer.to_string(check.evaluation_interval_seconds || @default_interval),
      "write_canonical_availability" =>
        if(Map.get(check, :write_canonical_availability, false), do: "true", else: "false")
    }
  end

  # A vantage point's freshness window must be at least as long as the sweep
  # cadence that feeds it, or the resolver returns :unknown for the whole
  # scope between runs. The old default was 900 seconds, which is shorter than
  # every sweep interval this ships with except the 5-minute one -- on hourly
  # sweeps it meant a check could only see one agent at a time, flipping to the
  # other as each agent's run landed, and reporting "0 of N devices have
  # results" for the rest of the hour.
  #
  # 3600 matches the common hourly group. It is deliberately biased long: an
  # over-long window accepts stale evidence, which the readiness panel shows,
  # while an over-short one silently produces no verdicts at all. The inline
  # warning in the form is what catches the mismatch either way, since no single
  # constant can be right for every sweep interval.
  @default_max_age 3600

  @doc """
  A blank vantage point row.

  `expected` defaults to blocked so that adding a second vantage point does not
  silently produce two witnesses; the operator picks which one is the witness.
  """
  def blank_vantage_point do
    %{
      "agent_id" => "",
      "expected" => "blocked",
      "max_age_seconds" => Integer.to_string(@default_max_age)
    }
  end

  @doc """
  Vantage point rows for an existing check's inputs.

  The input `key` is the agent id: it is unique per check by construction, which
  is what makes `unique_key_per_check` enforce one vantage point per agent, and
  it keeps rule match maps readable.
  """
  def vantage_points_from_inputs(inputs) do
    inputs
    |> Enum.filter(&(&1.kind == :vantage_point))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn input ->
      %{
        "agent_id" => Map.get(input.config, "agent_id", ""),
        "expected" => input.expected || "blocked",
        "max_age_seconds" => input.config |> Map.get("max_age_seconds", @default_max_age) |> to_string()
      }
    end)
  end

  @doc """
  Attributes for creating a `CompositeCheckInput` from a vantage point row.

  `label` is the agent's display name, and it is what the rule table columns,
  the preview breakdown, and the sweep coverage panel show. Defaulting it to the
  agent id would name the same vantage point two different ways on one page —
  the picker shows the agent's name, so those surfaces must too.
  """
  def vantage_point_attrs(check_id, row, position, label \\ nil) do
    agent_id = String.trim(row["agent_id"] || "")

    %{
      check_id: check_id,
      key: agent_id,
      label: blank_to_nil(label) || agent_id,
      position: position,
      kind: :vantage_point,
      expected: row["expected"],
      config: %{
        "agent_id" => agent_id,
        "max_age_seconds" => parse_interval(row["max_age_seconds"]) || @default_max_age
      }
    }
  end

  @doc """
  A blank device fact row.

  `value_type` is fixed to boolean because that is the only type
  `Resolvers.DeviceMetadata` casts. Offering a free field would let an operator
  save a check whose fact can never resolve to anything but `unknown`.
  """
  def blank_device_fact do
    %{"path" => "", "value_type" => "boolean", "max_age_seconds" => ""}
  end

  @doc "Device fact rows for an existing check's inputs."
  def device_facts_from_inputs(inputs) do
    inputs
    |> Enum.filter(&(&1.kind == :device_metadata))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn input ->
      %{
        "path" => Map.get(input.config, "path", ""),
        "value_type" => Map.get(input.config, "value_type", "boolean"),
        "max_age_seconds" =>
          case Map.get(input.config, "max_age_seconds") do
            seconds when is_integer(seconds) -> Integer.to_string(seconds)
            _absent -> ""
          end
      }
    end)
  end

  @doc """
  Attributes for creating a `CompositeCheckInput` from a device fact row.

  The input `key` is the metadata path: unique per check by construction, and
  it is what rule match maps address, so a rule reads
  `%{"nco_acl_enforced" => true}` rather than `%{"input_3" => true}`.

  A blank max age omits the key entirely rather than sending nil. That is a real
  semantic difference in the resolver: without it the fact resolves on the
  stored value alone and needs no provenance, which is what keeps a key written
  by a path that records none usable at all.
  """
  def device_fact_attrs(check_id, row, position) do
    path = String.trim(row["path"] || "")

    config =
      then(%{"path" => path, "value_type" => "boolean"}, fn config ->
        case parse_interval(row["max_age_seconds"]) do
          nil -> config
          seconds -> Map.put(config, "max_age_seconds", seconds)
        end
      end)

    %{
      check_id: check_id,
      key: path,
      label: path,
      position: position,
      kind: :device_metadata,
      config: config
    }
  end

  @doc "Validation for the device fact rows the form can catch locally."
  def validate_device_facts(rows) do
    paths = rows |> Enum.map(&String.trim(&1["path"] || "")) |> Enum.reject(&(&1 == ""))

    []
    |> then(fn errors ->
      if Enum.any?(rows, &(String.trim(&1["path"] || "") == "")) do
        [{"device_facts", "Every device fact needs a metadata key"} | errors]
      else
        errors
      end
    end)
    |> then(fn errors ->
      if length(Enum.uniq(paths)) == length(paths) do
        errors
      else
        [{"device_facts", "Each metadata key can only be used once"} | errors]
      end
    end)
    |> then(fn errors ->
      # Blank is legal (no freshness requirement). A non-numeric or non-positive
      # entry is not, and the resource rejects it, so catch it here where the
      # operator can see which row is wrong.
      if Enum.any?(rows, &invalid_max_age?/1) do
        [{"device_facts", "Max age must be a whole number of seconds above zero"} | errors]
      else
        errors
      end
    end)
  end

  defp invalid_max_age?(row) do
    raw = String.trim(to_string(row["max_age_seconds"] || ""))

    case {raw, parse_interval(raw)} do
      {"", _parsed} -> false
      {_raw, nil} -> true
      {_raw, seconds} -> seconds <= 0
    end
  end

  @doc """
  Validation for the vantage point rows the form can catch locally.

  The liveness witness rule is deliberately NOT enforced here. It gates
  *enabling*, not saving, and is owned by `CompositeChecks.Readiness` — an
  operator must be able to save a half-built check.
  """
  def validate_vantage_points(rows) do
    agent_ids = rows |> Enum.map(&String.trim(&1["agent_id"] || "")) |> Enum.reject(&(&1 == ""))

    []
    |> then(fn errors ->
      if Enum.any?(rows, &(String.trim(&1["agent_id"] || "") == "")) do
        [{"vantage_points", "Every vantage point needs an agent"} | errors]
      else
        errors
      end
    end)
    |> then(fn errors ->
      if length(Enum.uniq(agent_ids)) == length(agent_ids) do
        errors
      else
        [{"vantage_points", "Each agent can only be a vantage point once"} | errors]
      end
    end)
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
      evaluation_interval_seconds: parse_interval(form["evaluation_interval_seconds"]),
      write_canonical_availability: form["write_canonical_availability"] in [true, "true"]
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
