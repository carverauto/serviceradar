defmodule ServiceRadar.Plugins.PayloadUtils do
  @moduledoc false

  @spec payload_size_bytes(map()) :: non_neg_integer()
  def payload_size_bytes(payload) when is_map(payload) do
    payload
    |> Jason.encode!()
    |> byte_size()
  end

  @spec validate_payload_sizes([map()], pos_integer(), String.t()) ::
          :ok | {:error, [String.t()]}
  def validate_payload_sizes(payloads, hard_limit, message) do
    oversized = Enum.any?(payloads, &(payload_size_bytes(&1) > hard_limit))

    if oversized do
      {:error, [message]}
    else
      :ok
    end
  end

  @spec enforce_size_chunks([list()], (list() -> {:ok, [list()]} | {:error, [String.t()]})) ::
          {:ok, [list()]} | {:error, [String.t()]}
  def enforce_size_chunks(chunks, split_chunk_fun) when is_function(split_chunk_fun, 1) do
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case split_chunk_fun.(chunk) do
        {:ok, split_chunks} -> {:cont, {:ok, acc ++ split_chunks}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec split_chunk_until_fits(
          list(),
          pos_integer(),
          pos_integer(),
          (list() -> map()),
          String.t()
        ) :: {:ok, [list()]} | {:error, [String.t()]}
  def split_chunk_until_fits(chunk, hard_limit, max_items, payload_builder, oversized_message)
      when is_list(chunk) and is_integer(hard_limit) and hard_limit > 0 and is_integer(max_items) and
             max_items > 0 and
             is_function(payload_builder, 1) do
    do_split_chunk_until_fits(chunk, hard_limit, max_items, payload_builder, oversized_message)
  end

  defp do_split_chunk_until_fits([], _hard_limit, _max_items, _payload_builder, _message),
    do: {:ok, []}

  defp do_split_chunk_until_fits(chunk, hard_limit, max_items, payload_builder, message) do
    size = chunk |> payload_builder.() |> payload_size_bytes()

    cond do
      size <= hard_limit and length(chunk) <= max_items ->
        {:ok, [chunk]}

      length(chunk) == 1 ->
        {:error, [message]}

      true ->
        midpoint = div(length(chunk), 2)
        {left, right} = Enum.split(chunk, midpoint)

        with {:ok, left_chunks} <-
               do_split_chunk_until_fits(left, hard_limit, max_items, payload_builder, message),
             {:ok, right_chunks} <-
               do_split_chunk_until_fits(right, hard_limit, max_items, payload_builder, message) do
          {:ok, left_chunks ++ right_chunks}
        end
    end
  end

  @spec clamp_chunk_size(term(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp_chunk_size(value, default, max_items)
      when is_integer(default) and default > 0 and is_integer(max_items) and max_items > 0 do
    if is_integer(value) and value > 0 do
      min(value, max_items)
    else
      default
    end
  end

  @spec validate_schema_and_size(map(), map(), pos_integer(), String.t()) ::
          :ok | {:error, [String.t()]}
  def validate_schema_and_size(params, schema, hard_limit, hard_limit_message)
      when is_map(params) and is_map(schema) and is_integer(hard_limit) and hard_limit > 0 do
    resolved = ExJsonSchema.Schema.resolve(schema)

    case ExJsonSchema.Validator.validate(resolved, params) do
      :ok ->
        if payload_size_bytes(params) > hard_limit do
          {:error, [hard_limit_message]}
        else
          :ok
        end

      {:error, errors} ->
        {:error, Enum.map(errors, &format_validation_error/1)}
    end
  end

  @spec format_validation_error(term()) :: String.t()
  def format_validation_error(%ExJsonSchema.Validator.Error{} = error), do: inspect(error)
  def format_validation_error(other), do: inspect(other)
end
