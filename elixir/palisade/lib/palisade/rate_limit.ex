defmodule Palisade.RateLimit do
  @moduledoc """
  Behaviour for rate-limit backends.

  A backend answers one question: may `key` make another request, given at
  most `limit` requests per `window_ms` milliseconds? An allowed request is
  counted; a denied one is not.

  `Palisade.RateLimit.ETS` is the single-node backend that ships with
  palisade. A cluster-wide backend implements the same callback and is
  passed to `Palisade.Plug.RateLimit` as `backend: {MyBackend, opts}`.

  ## Results

    * `{:allow, remaining, reset_ms}` - the request is counted. `remaining`
      is how many more requests the key may make now, and `reset_ms` is how
      long until the current window ends.
    * `{:deny, retry_after_ms}` - the key is over its limit, or the backend
      cannot track it (for example, its table is full). `retry_after_ms` is
      at least 1.
  """

  @type key :: term()
  @type result ::
          {:allow, remaining :: non_neg_integer(), reset_ms :: non_neg_integer()}
          | {:deny, retry_after_ms :: pos_integer()}

  @doc """
  Checks and counts one request for `key`. `opts` are the backend's own
  options, as given in `backend: {module, opts}`.
  """
  @callback check(key(), limit :: pos_integer(), window_ms :: pos_integer(), opts :: keyword()) ::
              result()

  @doc """
  Calls `backend`'s `check/4`. `backend` is a module or `{module, opts}`.
  """
  @spec check(module() | {module(), keyword()}, key(), pos_integer(), pos_integer()) :: result()
  def check({module, opts}, key, limit, window_ms), do: module.check(key, limit, window_ms, opts)

  def check(module, key, limit, window_ms) when is_atom(module),
    do: check({module, []}, key, limit, window_ms)
end
