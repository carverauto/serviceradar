defmodule ServiceRadar.Plugins.TargetBatchParams do
  @moduledoc """
  Utilities for plugin target batch params (`serviceradar.plugin_target_batch_params.v1`).

  This module provides:
  - schema validation for batch payloads,
  - deterministic chunk hashing,
  - chunk generation with payload-size guardrails.
  """

  @schema_id "serviceradar.plugin_target_batch_params.v1"
  @soft_limit_bytes 262_144
  @hard_limit_bytes 1_000_000
  @max_targets_per_payload 500
  @default_chunk_size 100

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "schema",
      "policy_id",
      "policy_version",
      "agent_id",
      "chunk_index",
      "chunk_total",
      "chunk_hash",
      "generated_at",
      "targets"
    ],
    "properties" => %{
      "schema" => %{"type" => "string", "const" => @schema_id},
      "policy_id" => %{"type" => "string", "minLength" => 1},
      "policy_version" => %{"type" => "integer", "minimum" => 1},
      "agent_id" => %{"type" => "string", "minLength" => 1},
      "chunk_index" => %{"type" => "integer", "minimum" => 0},
      "chunk_total" => %{"type" => "integer", "minimum" => 1},
      "chunk_hash" => %{"type" => "string", "pattern" => "^[a-f0-9]{64}$"},
      "generated_at" => %{"type" => "string"},
      "template" => %{"type" => "object"},
      "targets" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => @max_targets_per_payload,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["uid"],
          "properties" => %{
            "uid" => %{"type" => "string", "minLength" => 1},
            "ip" => %{"type" => "string", "minLength" => 1},
            "hostname" => %{"type" => "string"},
            "vendor" => %{"type" => "string"},
            "model" => %{"type" => "string"},
            "site" => %{"type" => "string"},
            "zone" => %{"type" => "string"},
            "labels" => %{"type" => "object"},
            "stream_hints" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["protocol", "endpoint"],
                "properties" => %{
                  "protocol" => %{
                    "type" => "string",
                    "enum" => ["rtsp", "http", "https", "unknown"]
                  },
                  "endpoint" => %{"type" => "string", "minLength" => 1},
                  "profile" => %{"type" => "string"},
                  "auth_mode" => %{
                    "type" => "string",
                    "enum" => ["none", "basic", "digest", "basic_or_digest", "unknown"]
                  }
                }
              }
            }
          }
        }
      }
    }
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

    if batch_payload?(params) do
      do_validate(params)
    else
      :ok
    end
  end

  def validate(_), do: {:error, ["batch params must be an object"]}

  @spec payload_size_bytes(map()) :: non_neg_integer()
  def payload_size_bytes(payload) when is_map(payload) do
    payload
    |> Jason.encode!()
    |> byte_size()
  end

  @spec chunk_targets_with_limits(map(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def chunk_targets_with_limits(base_payload, targets, opts \\ [])

  def chunk_targets_with_limits(base_payload, targets, opts)
      when is_map(base_payload) and is_list(targets) do
    chunk_size = clamp_chunk_size(Keyword.get(opts, :chunk_size, @default_chunk_size))
    hard_limit = Keyword.get(opts, :hard_limit_bytes, @hard_limit_bytes)

    targets =
      targets
      |> Enum.map(&normalize_target/1)
      |> Enum.sort_by(&Map.get(&1, "uid", ""))

    chunks = Enum.chunk_every(targets, chunk_size)

    with {:ok, sized_chunks} <- enforce_size_chunks(base_payload, chunks, hard_limit),
         {:ok, payloads} <- build_payloads(base_payload, sized_chunks),
         :ok <- validate_payload_sizes(payloads, hard_limit) do
      {:ok, payloads}
    else
      {:error, _} = error -> error
    end
  end

  def chunk_targets_with_limits(_base_payload, _targets, _opts),
    do: {:error, ["base payload must be an object and targets must be a list"]}

  defp build_payloads(base_payload, chunks) do
    payload_base = stringify_keys(base_payload)
    total = length(chunks)

    payloads =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        chunk_hash = chunk_hash(chunk)

        payload_base
        |> Map.put("schema", @schema_id)
        |> Map.put("chunk_index", index)
        |> Map.put("chunk_total", total)
        |> Map.put("chunk_hash", chunk_hash)
        |> Map.put("targets", chunk)
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
    oversized =
      Enum.filter(payloads, fn payload ->
        payload_size_bytes(payload) > hard_limit
      end)

    if oversized == [] do
      :ok
    else
      {:error, ["generated batch payload exceeds hard size limit"]}
    end
  end

  defp enforce_size_chunks(base_payload, chunks, hard_limit) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case split_chunk_until_fits(base_payload, chunk, hard_limit) do
        {:ok, split_chunks} -> {:cont, {:ok, acc ++ split_chunks}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp split_chunk_until_fits(base_payload, chunk, hard_limit) do
    if chunk == [] do
      {:ok, []}
    else
      test_payload =
        base_payload
        |> stringify_keys()
        |> Map.put("schema", @schema_id)
        |> Map.put("chunk_index", 0)
        |> Map.put("chunk_total", 1)
        |> Map.put("chunk_hash", chunk_hash(chunk))
        |> Map.put("targets", chunk)

      size = payload_size_bytes(test_payload)

      cond do
        size <= hard_limit and length(chunk) <= @max_targets_per_payload ->
          {:ok, [chunk]}

        length(chunk) == 1 ->
          {:error, ["single target payload exceeds hard size limit"]}

        true ->
          midpoint = div(length(chunk), 2)
          {left, right} = Enum.split(chunk, midpoint)

          with {:ok, left_chunks} <- split_chunk_until_fits(base_payload, left, hard_limit),
               {:ok, right_chunks} <- split_chunk_until_fits(base_payload, right, hard_limit) do
            {:ok, left_chunks ++ right_chunks}
          end
      end
    end
  end

  defp do_validate(params) do
    resolved = ExJsonSchema.Schema.resolve(@schema)

    case ExJsonSchema.Validator.validate(resolved, params) do
      :ok ->
        size = payload_size_bytes(params)

        if size > @hard_limit_bytes do
          {:error, ["batch payload exceeds hard size limit of #{@hard_limit_bytes} bytes"]}
        else
          :ok
        end

      {:error, errors} ->
        {:error, Enum.map(errors, &format_error/1)}
    end
  end

  defp batch_payload?(%{"schema" => @schema_id}), do: true
  defp batch_payload?(%{"targets" => _}), do: true
  defp batch_payload?(_), do: false

  defp normalize_target(target) when is_map(target) do
    target
    |> stringify_keys()
    |> Map.take([
      "uid",
      "ip",
      "hostname",
      "vendor",
      "model",
      "site",
      "zone",
      "labels",
      "stream_hints"
    ])
  end

  defp normalize_target(_), do: %{}

  defp chunk_hash(targets) do
    hash =
      targets
      |> Enum.sort_by(&Map.get(&1, "uid", ""))
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(hash, case: :lower)
  end

  defp clamp_chunk_size(value) when is_integer(value) and value > 0 do
    min(value, @max_targets_per_payload)
  end

  defp clamp_chunk_size(_), do: @default_chunk_size

  defp stringify_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp format_error(%ExJsonSchema.Validator.Error{} = error), do: inspect(error)

  defp format_error(other), do: inspect(other)
end
