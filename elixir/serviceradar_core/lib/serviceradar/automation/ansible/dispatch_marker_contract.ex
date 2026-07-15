defmodule ServiceRadar.Automation.Ansible.DispatchMarkerContract do
  @moduledoc """
  Defines the dispatcher-owned AWX survey channel for launch markers.

  AWX 24.6.1 ignores undeclared Job Template `extra_vars` when
  `ask_variables_on_launch` is disabled. Enabling that prompt would let the
  launch endpoint accept arbitrary variables. The hardened launch path instead
  keeps the broad prompt disabled and requires an enabled survey with exactly
  these two server-owned marker declarations. AWX then accepts the markers but
  continues to reject every undeclared variable.

  This module validates only the reserved marker portion of the survey. Any
  additional survey fields remain governed by the binding's reviewed,
  non-secret input schema and the complete AWX review snapshot.
  """

  @schema "serviceradar.awx_dispatch_marker_survey/v1"
  @channel "restricted_awx_survey"
  @dispatch_id "serviceradar_dispatch_id"
  @snapshot_digest "serviceradar_snapshot_digest"

  @marker_fields [
    %{
      "variable" => @dispatch_id,
      "type" => "text",
      "required" => true,
      "min" => 36,
      "max" => 36
    },
    %{
      "variable" => @snapshot_digest,
      "type" => "text",
      "required" => true,
      "min" => 64,
      "max" => 64
    }
  ]
  @marker_names MapSet.new([@dispatch_id, @snapshot_digest])

  @doc "Returns the exact review-metadata contract required by hardened bindings."
  @spec contract() :: map()
  def contract do
    %{
      "schema" => @schema,
      "channel" => @channel,
      "survey_enabled" => true,
      "ask_variables_on_launch" => false,
      "fields" => @marker_fields
    }
  end

  @doc "Extracts and validates the marker contract from binding review metadata."
  @spec from_review_metadata(term()) :: {:ok, map()} | {:error, term()}
  def from_review_metadata(metadata) when is_map(metadata) do
    case unique_string_map(metadata) do
      {:ok, normalized} -> validate_contract(normalized["dispatch_marker_contract"])
      :error -> {:error, :binding_dispatch_marker_contract_invalid}
    end
  end

  def from_review_metadata(_metadata), do: {:error, :binding_dispatch_marker_contract_required}

  @doc "Validates an already extracted marker contract."
  @spec validate_contract(term()) :: {:ok, map()} | {:error, term()}
  def validate_contract(value) do
    expected = contract()

    case normalize(value) do
      {:ok, ^expected} -> {:ok, expected}
      _ -> {:error, :binding_dispatch_marker_contract_invalid}
    end
  end

  @doc "Returns true for either reserved marker name, case-insensitively."
  @spec reserved_name?(term()) :: boolean()
  def reserved_name?(name) when is_binary(name),
    do: MapSet.member?(@marker_names, String.downcase(name))

  def reserved_name?(_name), do: false

  @doc "Validates one raw AWX survey field when it names a reserved marker."
  @spec validate_survey_field(term()) :: :not_marker | :ok | {:error, term()}
  def validate_survey_field(field) when is_map(field) do
    case unique_string_map(field) do
      {:ok, normalized} ->
        name = normalized["variable"]

        cond do
          not reserved_name?(name) ->
            :not_marker

          name != String.downcase(name) ->
            {:error, :invalid_dispatch_marker_survey}

          true ->
            validate_marker_field(normalized, marker_spec(name))
        end

      :error ->
        {:error, :invalid_dispatch_marker_survey}
    end
  end

  def validate_survey_field(_field), do: :not_marker

  defp marker_spec(name), do: Enum.find(@marker_fields, &(&1["variable"] == name))

  defp validate_marker_field(field, expected) when is_map(expected) do
    if field["type"] == expected["type"] and
         field["required"] == expected["required"] and
         field["min"] == expected["min"] and
         field["max"] == expected["max"] and
         field["choices"] in [nil, "", []] and
         field["default"] in [nil, ""] do
      :ok
    else
      {:error, :invalid_dispatch_marker_survey}
    end
  end

  defp validate_marker_field(_field, _expected), do: {:error, :invalid_dispatch_marker_survey}

  defp normalize(value) when is_map(value) do
    with {:ok, map} <- unique_string_map(value) do
      Enum.reduce_while(map, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
        case normalize(nested) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp normalize(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, acc} ->
      case normalize(nested) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(_value), do: :error

  defp unique_string_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(key) and not Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:halt, :error}
      end
    end)
  end
end
