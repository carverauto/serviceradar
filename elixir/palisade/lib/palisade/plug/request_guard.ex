defmodule Palisade.Plug.RequestGuard do
  @moduledoc """
  Rejects malformed or oversized requests before they reach the router.

  | Check                                              | Status |
  | -------------------------------------------------- | ------ |
  | GET or HEAD with a body or `transfer-encoding`     | 400    |
  | query parameter outside the allow-list             | 400    |
  | query string longer than `:max_query_length`       | 414    |
  | more than `:max_headers` request headers           | 431    |

  A GET or HEAD carries a body when it has a `transfer-encoding` header or a
  `content-length` other than `0`. Such requests are a request-smuggling and
  cache-poisoning vector, and no route here expects them.

  ## Options

    * `:max_query_length` - bytes. Default `4096`.
    * `:max_headers` - default `100`.
    * `:allowed_query_params` - restricts query parameter names. One of:
      * `nil` (default): any names,
      * a list of names, applied to every request through this plug,
      * a map of request path to a list of names; paths not in the map are
        unrestricted,
      * a 1-arity function of the conn returning a list, or `nil` for no
        restriction.

      Names are compared on the part before any `[`, so allowing `"filter"`
      allows `filter[name]=x`.
    * `:on_reject` - a 3-arity function `(conn, status, reason) -> conn`
      that builds the rejection instead of the default plain-text body. The
      plug halts the returned conn. If it returns a conn that was not sent,
      the default response is sent. `reason` is one of `:body_on_get`,
      `:query_param_not_allowed`, `:query_too_long`, `:too_many_headers`.

  ## Example

      # In the endpoint, ahead of Plug.Parsers and the router:
      plug Palisade.Plug.RequestGuard, max_query_length: 2048

      # In a router pipeline, for routes with a known set of parameters:
      plug Palisade.Plug.RequestGuard,
        allowed_query_params: %{"/search" => ["q", "page"], "/devices" => ["filter", "sort"]}
  """

  @behaviour Plug

  import Plug.Conn

  @bodiless_methods ["GET", "HEAD"]

  @messages %{
    body_on_get: "Request body not allowed",
    query_param_not_allowed: "Query parameter not allowed",
    query_too_long: "Query string too long",
    too_many_headers: "Too many request headers"
  }

  @impl Plug
  def init(opts) do
    max_query_length = Keyword.get(opts, :max_query_length, 4096)
    max_headers = Keyword.get(opts, :max_headers, 100)
    allowed = Keyword.get(opts, :allowed_query_params)
    on_reject = Keyword.get(opts, :on_reject)

    if !(is_integer(max_query_length) and max_query_length > 0),
      do: invalid!(:max_query_length, max_query_length)

    if !(is_integer(max_headers) and max_headers > 0), do: invalid!(:max_headers, max_headers)
    if !(is_nil(on_reject) or is_function(on_reject, 3)), do: invalid!(:on_reject, on_reject)

    %{
      max_query_length: max_query_length,
      max_headers: max_headers,
      allowed_query_params: allowed_query_params!(allowed),
      on_reject: on_reject
    }
  end

  @impl Plug
  def call(conn, config) do
    case check(conn, config) do
      :ok -> conn
      {status, reason} -> conn |> reject(status, reason, config) |> halt()
    end
  end

  defp check(conn, config) do
    cond do
      length(conn.req_headers) > config.max_headers ->
        {431, :too_many_headers}

      byte_size(conn.query_string) > config.max_query_length ->
        {414, :query_too_long}

      body_on_bodiless?(conn) ->
        {400, :body_on_get}

      not query_params_allowed?(conn, config.allowed_query_params) ->
        {400, :query_param_not_allowed}

      true ->
        :ok
    end
  end

  defp body_on_bodiless?(%Plug.Conn{method: method} = conn) when method in @bodiless_methods do
    get_req_header(conn, "transfer-encoding") != [] or
      Enum.any?(get_req_header(conn, "content-length"), &(String.trim(&1) != "0"))
  end

  defp body_on_bodiless?(_conn), do: false

  defp query_params_allowed?(_conn, nil), do: true
  defp query_params_allowed?(%Plug.Conn{query_string: ""}, _allowed), do: true

  defp query_params_allowed?(conn, {:all, names}), do: names_allowed?(conn.query_string, names)

  defp query_params_allowed?(conn, {:by_path, by_path}) do
    case Map.fetch(by_path, conn.request_path) do
      {:ok, names} -> names_allowed?(conn.query_string, names)
      :error -> true
    end
  end

  defp query_params_allowed?(conn, {:dynamic, fun}) do
    case fun.(conn) do
      nil -> true
      names when is_list(names) -> names_allowed?(conn.query_string, MapSet.new(names))
    end
  end

  defp names_allowed?(query_string, allowed) do
    query_string
    |> URI.query_decoder()
    |> Enum.all?(fn {name, _value} -> base_name(name) in allowed end)
  end

  defp base_name(name), do: name |> :binary.split("[") |> hd()

  defp reject(conn, status, reason, %{on_reject: on_reject}) when is_function(on_reject, 3) do
    case on_reject.(conn, status, reason) do
      %Plug.Conn{state: :unset} = conn -> default_reject(conn, status, reason)
      %Plug.Conn{} = conn -> conn
    end
  end

  defp reject(conn, status, reason, _config), do: default_reject(conn, status, reason)

  defp default_reject(conn, status, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, Map.fetch!(@messages, reason))
  end

  defp allowed_query_params!(nil), do: nil
  defp allowed_query_params!(fun) when is_function(fun, 1), do: {:dynamic, fun}
  defp allowed_query_params!(names) when is_list(names), do: {:all, names_set!(names)}

  defp allowed_query_params!(by_path) when is_map(by_path) do
    {:by_path,
     Map.new(by_path, fn
       {path, names} when is_binary(path) and is_list(names) -> {path, names_set!(names)}
       other -> invalid!(:allowed_query_params, other)
     end)}
  end

  defp allowed_query_params!(other), do: invalid!(:allowed_query_params, other)

  defp names_set!(names) do
    if Enum.all?(names, &is_binary/1),
      do: MapSet.new(names),
      else: invalid!(:allowed_query_params, names)
  end

  @spec invalid!(atom(), term()) :: no_return()
  defp invalid!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
  end
end
