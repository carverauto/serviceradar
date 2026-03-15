defmodule ServiceRadar.Plugins.PluginInputs do
  @moduledoc """
  First-class generic plugin input payload contract.

  Schema: `serviceradar.plugin_inputs.v1`

  This payload allows control-plane resolved SRQL inputs (devices, interfaces,
  or other entities) to be passed to WASM plugins without plugin-side SRQL
  execution or API credentials.
  """

  alias ServiceRadar.Plugins.{IdentityUtils, MapUtils, PayloadUtils}

  @schema_id "serviceradar.plugin_inputs.v1"
  @soft_limit_bytes 262_144
  @hard_limit_bytes 1_000_000
  @max_items_per_input 500
  @default_chunk_size 100

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "schema",
      "policy_id",
      "policy_version",
      "agent_id",
      "generated_at",
      "inputs"
    ],
    "properties" => %{
      "schema" => %{"type" => "string", "const" => @schema_id},
      "policy_id" => %{"type" => "string", "minLength" => 1},
      "policy_version" => %{"type" => "integer", "minimum" => 1},
      "agent_id" => %{"type" => "string", "minLength" => 1},
      "generated_at" => %{"type" => "string"},
      "template" => %{"type" => "object"},
      "inputs" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "name",
            "entity",
            "query",
            "chunk_index",
            "chunk_total",
            "chunk_hash",
            "items"
          ],
          "properties" => %{
            "name" => %{"type" => "string", "minLength" => 1},
            "entity" => %{"type" => "string", "minLength" => 1},
            "query" => %{"type" => "string", "minLength" => 1},
            "chunk_index" => %{"type" => "integer", "minimum" => 0},
            "chunk_total" => %{"type" => "integer", "minimum" => 1},
            "chunk_hash" => %{"type" => "string", "pattern" => "^[a-f0-9]{64}$"},
            "items" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_items_per_input,
              "items" => %{"type" => "object"}
            }
          }
        }
      }
    }
  }

  @type input_descriptor :: %{
          required(:name) => String.t(),
          required(:entity) => String.t(),
          required(:query) => String.t()
        }

  @spec schema_id() :: String.t()
  def schema_id, do: @schema_id

  @spec soft_limit_bytes() :: pos_integer()
  def soft_limit_bytes, do: @soft_limit_bytes

  @spec hard_limit_bytes() :: pos_integer()
  def hard_limit_bytes, do: @hard_limit_bytes

  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(params) when is_map(params) do
    params = stringify_keys(params)

    if plugin_inputs_payload?(params) do
      do_validate(params)
    else
      :ok
    end
  end

  def validate(_), do: {:error, ["plugin inputs payload must be an object"]}

  @spec payload_size_bytes(map()) :: non_neg_integer()
  def payload_size_bytes(payload) when is_map(payload),
    do: PayloadUtils.payload_size_bytes(payload)

  @spec chunk_single_input_payloads(map(), input_descriptor(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def chunk_single_input_payloads(base_payload, input, items, opts \\ [])

  def chunk_single_input_payloads(base_payload, input, items, opts)
      when is_map(base_payload) and is_map(input) and is_list(items) do
    chunk_size =
      PayloadUtils.clamp_chunk_size(
        Keyword.get(opts, :chunk_size, @default_chunk_size),
        @default_chunk_size,
        @max_items_per_input
      )

    hard_limit = Keyword.get(opts, :hard_limit_bytes, @hard_limit_bytes)

    normalized_items =
      items
      |> Enum.map(&normalize_item/1)
      |> Enum.sort_by(&item_sort_key/1)

    chunks = Enum.chunk_every(normalized_items, chunk_size)

    with {:ok, sized_chunks} <- enforce_size_chunks(base_payload, input, chunks, hard_limit),
         {:ok, payloads} <- build_payloads(base_payload, input, sized_chunks),
         :ok <- validate_payload_sizes(payloads, hard_limit) do
      {:ok, payloads}
    else
      {:error, _} = error -> error
    end
  end

  def chunk_single_input_payloads(_base_payload, _input, _items, _opts) do
    {:error, ["base payload/input/items types are invalid"]}
  end

  defp build_payloads(base_payload, input, chunks) do
    payload_base = MapUtils.stringify_keys(base_payload)
    input = MapUtils.stringify_keys(input)
    total = length(chunks)

    payloads =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        input_entry = %{
          "name" => Map.get(input, "name"),
          "entity" => Map.get(input, "entity"),
          "query" => Map.get(input, "query"),
          "chunk_index" => index,
          "chunk_total" => total,
          "chunk_hash" => chunk_hash(chunk),
          "items" => chunk
        }

        payload_base
        |> Map.put("schema", @schema_id)
        |> Map.put("inputs", [input_entry])
      end)

    errors =
      payloads
      |> Enum.flat_map(fn payload ->
        case do_validate(payload) do
          :ok -> []
          {:error, errs} -> errs
        end
      end)

    case errors do
      [] -> {:ok, payloads}
      _ -> {:error, errors}
    end
  end

  defp validate_payload_sizes(payloads, hard_limit) do
    PayloadUtils.validate_payload_sizes(
      payloads,
      hard_limit,
      "generated plugin inputs payload exceeds hard size limit"
    )
  end

  defp enforce_size_chunks(base_payload, input, chunks, hard_limit) do
    PayloadUtils.enforce_size_chunks(
      chunks,
      &split_chunk_until_fits(base_payload, input, &1, hard_limit)
    )
  end

  defp split_chunk_until_fits(base_payload, input, chunk, hard_limit) do
    PayloadUtils.split_chunk_until_fits(
      chunk,
      hard_limit,
      @max_items_per_input,
      &build_test_payload(base_payload, input, &1),
      "single input item exceeds hard size limit"
    )
  end

  defp build_test_payload(base_payload, input, chunk) do
    payload_base = MapUtils.stringify_keys(base_payload)
    input = MapUtils.stringify_keys(input)

    payload_base
    |> Map.put("schema", @schema_id)
    |> Map.put("inputs", [
      %{
        "name" => Map.get(input, "name"),
        "entity" => Map.get(input, "entity"),
        "query" => Map.get(input, "query"),
        "chunk_index" => 0,
        "chunk_total" => 1,
        "chunk_hash" => chunk_hash(chunk),
        "items" => chunk
      }
    ])
  end

  defp do_validate(params) do
    PayloadUtils.validate_schema_and_size(
      params,
      @schema,
      @hard_limit_bytes,
      "plugin inputs payload exceeds hard size limit of #{@hard_limit_bytes} bytes"
    )
  end

  defp plugin_inputs_payload?(%{"schema" => @schema_id}), do: true
  defp plugin_inputs_payload?(%{"inputs" => _}), do: true
  defp plugin_inputs_payload?(_), do: false

  defp normalize_item(%{} = item), do: stringify_keys(item)
  defp normalize_item(_), do: %{}

  defp item_sort_key(item) do
    IdentityUtils.item_identity(item)
  end

  defp chunk_hash(items) do
    IdentityUtils.chunk_hash(items, &item_sort_key/1)
  end

  defp stringify_keys(value), do: MapUtils.stringify_keys(value)
end
