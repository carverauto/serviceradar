defmodule ServiceRadarObjectStorage do
  @moduledoc """
  Bounded asynchronous Longshore operations over Rustler.

  This library exposes both the qualification helpers (`put/3`, `fetch/2`,
  `fetch_range/4`) and the verified single-attempt (`Budget::once` by default)
  operations (`put/4`, `put/5`, `head/3`, `head/4`, `get/4`, `get/5`) backed by
  `longshore_s3::Client::{put,head,get}` and `longshore_s3::report::Report`.

  Open accepts a map with `host`, `port`, `region`, `bucket` (or `nil`),
  `access_key`, `secret_key`, `session_token` (or `nil`), `tls`, `concurrency`,
  `buffer_size`, and optional `portable` (boolean, defaults to `false`; uses
  `epoll` on Linux instead of `io_uring`, while macOS always uses `kqueue`).
  Missing, unknown, or incorrectly typed fields return `{:error, :bad_config}`.
  Only numeric loopback hosts allow plaintext HTTP. TLS uses public roots.

  Verified operations default to `%{timeout_ms: 30_000}` (`Budget::once`) and
  return `{:ok, reference}` after admission or `{:error, reason}` immediately.
  Completion arrives at the admitting process as
  `{:longshore_reply, reference, {:ok, report} | {:error, reason}, {queue_us, operation_us}}`.
  Prefer `ServiceRadarObjectStorage.Session` as the supervised owner so caller
  timeouts or exits never strand late multi-MiB reply messages in caller
  mailboxes.
  """
  use Rustler,
    otp_app: :serviceradar_object_storage,
    crate: "longshore_nif",
    env: [{"CARGO_PROFILE_RELEASE_PANIC", "unwind"}]

  @default_budget %{timeout_ms: 30_000}

  def default_budget, do: @default_budget

  def open(_config), do: :erlang.nif_error(:nif_not_loaded)
  def put(_client, _key, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  def put(client, key, bytes, options) do
    put_object(client, key, bytes, options, @default_budget)
  end

  def put(client, key, bytes, options, budget) do
    put_object(client, key, bytes, options, budget)
  end

  def head(client, key, expect) do
    head_object(client, key, expect, @default_budget)
  end

  def head(client, key, expect, budget) do
    head_object(client, key, expect, budget)
  end

  def get(client, key, range, expect) do
    get_object(client, key, range, expect, @default_budget)
  end

  def get(client, key, range, expect, budget) do
    get_object(client, key, range, expect, budget)
  end

  def put_object(_client, _key, _bytes, _options, _budget), do: :erlang.nif_error(:nif_not_loaded)

  def head_object(_client, _key, _expect, _budget), do: :erlang.nif_error(:nif_not_loaded)

  def get_object(_client, _key, _range, _expect, _budget), do: :erlang.nif_error(:nif_not_loaded)

  def fetch(_client, _key), do: :erlang.nif_error(:nif_not_loaded)
  def fetch_range(_client, _key, _first, _last), do: :erlang.nif_error(:nif_not_loaded)
  def close(_client), do: :erlang.nif_error(:nif_not_loaded)
  def info(_client), do: :erlang.nif_error(:nif_not_loaded)
end
