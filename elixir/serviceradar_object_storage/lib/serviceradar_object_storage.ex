defmodule ServiceRadarObjectStorage do
  @moduledoc """
  Bounded asynchronous Longshore operations for storage qualification.

  This client does not issue archive receipts or authorize local reclamation.
  Longshore retries internally; a timeout or caller exit does not cancel I/O.
  The existing archive provider remains responsible for production authority.

  Open accepts a map with host, port, region, bucket (or nil), access_key,
  secret_key, session_token (or nil), tls, concurrency and buffer_size.
  Missing, unknown or incorrectly typed fields return {:error, :bad_config}.
  Only numeric loopback hosts allow plaintext HTTP. TLS uses public roots.
  Each client owns one I/O thread and at most concurrency native workers.
  There are at most two live clients per VM, including draining clients.
  Concurrency is 1..16, buffers are 8 KiB..16 MiB and their aggregate payload
  capacity is at most 64 MiB per client. TLS and copied payloads are additional.

  Operations return {:ok, reference} after admission or {:error, reason}.
  Completion is {:longshore_reply, reference, result, {queue_us, operation_us}}.
  Put is conditional: success is {:ok, :stored} or {:ok, :already_exists}.
  Fetch returns {:ok, bytes} or {:ok, :not_found}. Callers must treat missing
  or failed mutation replies as unknown, without automatically resubmitting.
  Replies can arrive after an application deadline. Prefer a supervised
  operation owner that retains correlation until completion.

  Close refuses new admissions and drains admitted work; it does not cancel.
  info/1 reports outstanding operations and remaining workers. Shutdown is
  complete when accepting is false and workers is zero. Dropping the resource
  also drains it, without joining native threads on a BEAM scheduler.
  """
  use Rustler,
    otp_app: :serviceradar_object_storage,
    crate: "longshore_nif",
    env: [{"CARGO_PROFILE_RELEASE_PANIC", "unwind"}]

  def open(_config), do: :erlang.nif_error(:nif_not_loaded)
  def put(_client, _key, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  def fetch(_client, _key), do: :erlang.nif_error(:nif_not_loaded)
  def fetch_range(_client, _key, _first, _last), do: :erlang.nif_error(:nif_not_loaded)
  def close(_client), do: :erlang.nif_error(:nif_not_loaded)
  def info(_client), do: :erlang.nif_error(:nif_not_loaded)
end
