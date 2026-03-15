defmodule ServiceRadar.Plugins.TargetBatchParams do
  @moduledoc """
  Utilities for plugin target batch params (`serviceradar.plugin_target_batch_params.v1`).

  This module provides:
  - schema validation for batch payloads,
  - deterministic chunk hashing,
  - chunk generation with payload-size guardrails.
  """

  alias ServiceRadar.Plugins.IdentityUtils
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PayloadUtils

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
  def payload_size_bytes(payload) when is_map(payload),
    do: PayloadUtils.payload_size_bytes(payload)

  @spec chunk_targets_with_limits(map(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def chunk_targets_with_limits(base_payload, targets, opts \\ [])

  def chunk_targets_with_limits(base_payload, targets, opts)
      when is_map(base_payload) and is_list(targets) do
    chunk_size =
      PayloadUtils.clamp_chunk_size(
        Keyword.get(opts, :chunk_size, @default_chunk_size),
        @default_chunk_size,
        @max_targets_per_payload
      )

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
    payload_base = MapUtils.stringify_keys(base_payload)
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
      Enum.flat_map(payloads, fn payload ->
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
      "generated batch payload exceeds hard size limit"
    )
  end

  defp enforce_size_chunks(base_payload, chunks, hard_limit) do
    PayloadUtils.enforce_size_chunks(
      chunks,
      &split_chunk_until_fits(base_payload, &1, hard_limit)
    )
  end

  defp split_chunk_until_fits(base_payload, chunk, hard_limit) do
    PayloadUtils.split_chunk_until_fits(
      chunk,
      hard_limit,
      @max_targets_per_payload,
      &build_test_payload(base_payload, &1),
      "single target payload exceeds hard size limit"
    )
  end

  defp build_test_payload(base_payload, chunk) do
    base_payload
    |> MapUtils.stringify_keys()
    |> Map.put("schema", @schema_id)
    |> Map.put("chunk_index", 0)
    |> Map.put("chunk_total", 1)
    |> Map.put("chunk_hash", chunk_hash(chunk))
    |> Map.put("targets", chunk)
  end

  defp do_validate(params) do
    PayloadUtils.validate_schema_and_size(
      params,
      @schema,
      @hard_limit_bytes,
      "batch payload exceeds hard size limit of #{@hard_limit_bytes} bytes"
    )
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
    IdentityUtils.chunk_hash(targets, &Map.get(&1, "uid", ""))
  end

  defp stringify_keys(value), do: MapUtils.stringify_keys(value)
end
