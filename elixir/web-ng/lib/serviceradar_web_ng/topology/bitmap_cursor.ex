defmodule ServiceRadarWebNG.Topology.BitmapCursor do
  @moduledoc "Authenticated live-membership keyset position, independent of a pod or index revision."

  alias ServiceRadarWebNGWeb.Endpoint

  @salt "topology-live-bitmap-cursor-v1"
  @ttl_seconds 300

  def sign(context, ordinal) when is_integer(ordinal) and ordinal in 1..4_294_967_295 do
    Phoenix.Token.sign(Endpoint, @salt, {
      context.dictionary_epoch,
      :device,
      context.query_digest,
      context.authority,
      ordinal
    })
  end

  def after_ordinal(nil, _context), do: {:ok, 0}

  def after_ordinal(token, context) when is_binary(token) and byte_size(token) <= 2_048 do
    with {:ok, {dictionary, :device, digest, authority, ordinal}} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @ttl_seconds),
         true <- dictionary == context.dictionary_epoch and digest == context.query_digest,
         true <- authority == context.authority,
         true <- is_integer(ordinal) and ordinal in 1..4_294_967_295 do
      {:ok, ordinal}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def after_ordinal(_token, _context), do: {:error, :invalid_cursor}
end
