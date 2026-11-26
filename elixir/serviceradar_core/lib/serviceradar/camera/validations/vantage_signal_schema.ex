defmodule ServiceRadar.Camera.Validations.VantageSignalSchema do
  @moduledoc """
  Validates and resolves Vantage `signal_schema` definitions before passing
  them to `ExJsonSchema`, protecting against circular `$ref` chains,
  unresolvable internal `$ref` pointers, and non-map schemas while preserving
  nested property names such as `"$schema"`.
  """

  use Ash.Resource.Validation

  @ignored_properties ~w(const default enum examples)

  @doc """
  Validates `attributes` against a pack `signal_schema` map using `ExJsonSchema`
  after cycle-checking `$ref` chains and normalizing Draft 2020-12 keywords.
  """
  @spec validate_attributes(term(), term()) :: :ok | {:error, :signal_schema_violation}
  def validate_attributes(nil, attributes) when is_map(attributes) and not is_struct(attributes),
    do: :ok

  def validate_attributes(schema, attributes)
      when schema == %{} and is_map(attributes) and not is_struct(attributes),
      do: :ok

  def validate_attributes(schema, attributes)
      when is_map(schema) and not is_struct(schema) and is_map(attributes) and
             not is_struct(attributes) do
    with {:ok, resolved} <- resolve_schema(schema),
         :ok <- ExJsonSchema.Validator.validate(resolved, attributes) do
      :ok
    else
      _ -> {:error, :signal_schema_violation}
    end
  rescue
    _ -> {:error, :signal_schema_violation}
  end

  def validate_attributes(_, _), do: {:error, :signal_schema_violation}

  @doc """
  Normalizes a `signal_schema` map for `ExJsonSchema`, checks for circular or
  unresolvable `$ref` pointers, and resolves the schema deterministically.
  """
  @spec resolve_schema(term()) ::
          {:ok, ExJsonSchema.Schema.Root.t()} | {:error, :signal_schema_violation}
  def resolve_schema(schema) when is_map(schema) and not is_struct(schema) do
    normalized = draft4_compatible_schema(schema)

    case check_refs(normalized) do
      :ok -> {:ok, ExJsonSchema.Schema.resolve(normalized)}
      {:error, _} -> {:error, :signal_schema_violation}
    end
  rescue
    _ -> {:error, :signal_schema_violation}
  end

  def resolve_schema(_), do: {:error, :signal_schema_violation}

  @doc """
  Converts Draft 2020-12 `$defs`, `dependentRequired`, and `#/$defs/` pointers
  into Draft 4/7 equivalents, stripping `"$schema"` only at the top level so
  object properties named `"$schema"` remain intact.
  """
  @spec draft4_compatible_schema(map()) :: map()
  def draft4_compatible_schema(%{} = schema) when not is_struct(schema) do
    schema
    |> Map.delete("$schema")
    |> normalize_draft4_node()
  end

  defp normalize_draft4_node(value) when is_list(value),
    do: Enum.map(value, &normalize_draft4_node/1)

  defp normalize_draft4_node(%{} = map) when not is_struct(map) do
    defs_map =
      case {Map.get(map, "definitions"), Map.get(map, "$defs")} do
        {existing, extra} when is_map(existing) and is_map(extra) ->
          Map.merge(normalize_schema_map_values(existing), normalize_schema_map_values(extra))

        _ ->
          nil
      end

    normalized =
      Map.new(map, fn
        {"$defs", definitions} when is_map(definitions) ->
          {"definitions", defs_map || normalize_schema_map_values(definitions)}

        {"$defs", definitions} ->
          {"definitions", normalize_draft4_node(definitions)}

        {"definitions", definitions} when is_map(definitions) and not is_nil(defs_map) ->
          {"definitions", defs_map}

        {"dependentRequired", dependencies} ->
          {"dependencies", normalize_draft4_node(dependencies)}

        {"$ref", "#/$defs/" <> rest} ->
          {"$ref", "#/definitions/" <> rest}

        {"properties", props} when is_map(props) ->
          {"properties", normalize_schema_map_values(props)}

        {"patternProperties", props} when is_map(props) ->
          {"patternProperties", normalize_schema_map_values(props)}

        {key, nested} when key in @ignored_properties ->
          {key, nested}

        {key, nested} ->
          {key, normalize_draft4_node(nested)}
      end)

    normalized
  end

  defp normalize_draft4_node(value), do: value

  defp normalize_schema_map_values(map) when is_map(map) do
    Map.new(map, fn {prop_name, subschema} ->
      {prop_name, normalize_draft4_node(subschema)}
    end)
  end

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :signal_schema) do
      :error -> :ok
      {:ok, value} -> validate_changeset_value(value)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case fetch_pending_value(changeset) do
      :unchanged ->
        :ok

      {:ok, value} ->
        validate_changeset_value(value)
    end
  end

  defp fetch_pending_value(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :signal_schema),
         :error <- Ash.Changeset.fetch_change(changeset, :signal_schema) do
      :unchanged
    end
  end

  defp validate_changeset_value(value) when value == %{}, do: :ok

  defp validate_changeset_value(value) when is_map(value) and not is_struct(value) do
    case resolve_schema(value) do
      {:ok, _resolved} ->
        :ok

      {:error, :signal_schema_violation} ->
        {:error, field: :signal_schema, message: "must be a valid, acyclic JSON Schema"}
    end
  end

  defp validate_changeset_value(_) do
    {:error, field: :signal_schema, message: "must be a valid, acyclic JSON Schema"}
  end

  defp check_refs(root) when is_map(root) do
    case walk_node(root, [], root, MapSet.new([[]]), MapSet.new()) do
      {:ok, _verified} -> :ok
      {:error, _} = error -> error
    end
  end

  defp walk_node(node, path, root, stack, verified) do
    if MapSet.member?(verified, path) do
      {:ok, verified}
    else
      do_walk_node(node, path, root, stack, verified)
    end
  end

  defp do_walk_node(node, path, root, stack, verified)
       when is_map(node) and not is_struct(node) do
    with {:ok, verified} <- maybe_follow_ref(node, root, stack, verified),
         {:ok, verified} <- walk_children(node, path, root, stack, verified) do
      {:ok, MapSet.put(verified, path)}
    end
  end

  defp do_walk_node(node, path, root, stack, verified) when is_list(node) do
    node
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, verified}, fn {item, idx}, {:ok, acc_verified} ->
      child_path = path ++ [Integer.to_string(idx)]

      case walk_node(item, child_path, root, MapSet.put(stack, child_path), acc_verified) do
        {:ok, next_verified} -> {:cont, {:ok, next_verified}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, next_verified} -> {:ok, MapSet.put(next_verified, path)}
      {:error, _} = err -> err
    end
  end

  defp do_walk_node(_primitive, path, _root, _stack, verified) do
    {:ok, MapSet.put(verified, path)}
  end

  defp maybe_follow_ref(%{"$ref" => ref}, root, stack, verified) when is_binary(ref) do
    with {:ok, target_path} <- parse_internal_pointer(ref),
         {:ok, target_node} <- resolve_pointer(root, target_path),
         true <- (is_map(target_node) or is_boolean(target_node)) || {:error, :invalid_ref} do
      if MapSet.member?(stack, target_path) do
        {:error, :circular_ref}
      else
        walk_node(target_node, target_path, root, MapSet.put(stack, target_path), verified)
      end
    end
  end

  defp maybe_follow_ref(%{"$ref" => _invalid}, _root, _stack, _verified),
    do: {:error, :invalid_ref}

  defp maybe_follow_ref(_node, _root, _stack, verified), do: {:ok, verified}

  defp walk_children(node, path, root, stack, verified) do
    Enum.reduce_while(node, {:ok, verified}, fn {key, child}, {:ok, acc_verified} ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, :invalid_schema_key}}

        key == "$ref" or key in @ignored_properties ->
          {:cont, {:ok, acc_verified}}

        key in ["properties", "patternProperties", "definitions"] and is_map(child) ->
          case walk_subschema_map(child, path ++ [key], root, stack, acc_verified) do
            {:ok, next_verified} -> {:cont, {:ok, next_verified}}
            {:error, _} = err -> {:halt, err}
          end

        is_map(child) or is_list(child) ->
          child_path = path ++ [key]

          case walk_node(child, child_path, root, MapSet.put(stack, child_path), acc_verified) do
            {:ok, next_verified} -> {:cont, {:ok, next_verified}}
            {:error, _} = err -> {:halt, err}
          end

        true ->
          {:cont, {:ok, acc_verified}}
      end
    end)
  end

  defp walk_subschema_map(map, base_path, root, stack, verified) do
    Enum.reduce_while(map, {:ok, verified}, fn {k, sub}, {:ok, acc_verified} ->
      if is_binary(k) do
        child_path = base_path ++ [k]

        case walk_node(sub, child_path, root, MapSet.put(stack, child_path), acc_verified) do
          {:ok, next_verified} -> {:cont, {:ok, next_verified}}
          {:error, _} = err -> {:halt, err}
        end
      else
        {:halt, {:error, :invalid_schema_key}}
      end
    end)
  end

  defp parse_internal_pointer("#"), do: {:ok, []}

  defp parse_internal_pointer("#/" <> rest) do
    segments =
      rest
      |> String.split("/", trim: false)
      |> Enum.map(fn seg ->
        seg
        |> URI.decode()
        |> String.replace("~1", "/")
        |> String.replace("~0", "~")
      end)

    {:ok, segments}
  end

  defp parse_internal_pointer(_), do: {:error, :unresolvable_ref}

  defp resolve_pointer(node, []), do: {:ok, node}

  defp resolve_pointer(node, [seg | rest]) when is_map(node) and not is_struct(node) do
    case Map.fetch(node, seg) do
      {:ok, next} -> resolve_pointer(next, rest)
      :error -> {:error, :unresolvable_ref}
    end
  end

  defp resolve_pointer(node, [seg | rest]) when is_list(node) do
    case Integer.parse(seg) do
      {idx, ""} when idx >= 0 ->
        case Enum.fetch(node, idx) do
          {:ok, next} -> resolve_pointer(next, rest)
          :error -> {:error, :unresolvable_ref}
        end

      _ ->
        {:error, :unresolvable_ref}
    end
  end

  defp resolve_pointer(_, _), do: {:error, :unresolvable_ref}
end
