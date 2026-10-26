defmodule ServiceRadar.TestSupport.ExposureBroker do
  @moduledoc false
  import ExUnit.Assertions

  alias ServiceRadar.NATS.Connection

  def with_broker(dir, fun) do
    {:ok, _} = Application.ensure_all_started(:gnat)

    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    File.mkdir_p!(dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-js",
          "-a",
          "127.0.0.1",
          "-p",
          "-1",
          "-sd",
          Path.join(dir, "store"),
          "--ports_file_dir",
          dir,
          "-l",
          Path.join(dir, "broker.log")
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      broker_port = broker_port(dir, pid, 300)
      conn = connect(broker_port)
      fun.(conn, broker_port)
    after
      if conn = Process.whereis(Connection.connection_name()), do: Gnat.stop(conn)
      {_output, 0} = System.cmd(executable, ["--signal", "quit=#{pid}"], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, 0}}, 30_000
    end
  end

  def connect(port) do
    {:ok, conn} =
      Gnat.start_link(%{host: "127.0.0.1", port: port}, name: Connection.connection_name())

    conn
  end

  def request(conn, subject, payload) do
    {:ok, %{body: body}} =
      Gnat.request(conn, subject, Jason.encode!(payload), receive_timeout: 5_000)

    Jason.decode!(body)
  end

  defp broker_port(dir, pid, attempts) do
    case File.read(Path.join(dir, "nats-server_#{pid}.ports")) do
      {:ok, body} ->
        %{"nats" => [uri]} = Jason.decode!(body)
        URI.parse(uri).port

      {:error, :enoent} ->
        assert attempts > 0, "disposable NATS broker did not start"
        Process.sleep(100)
        broker_port(dir, pid, attempts - 1)
    end
  end
end
