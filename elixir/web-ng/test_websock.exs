defmodule TestWebSock do
  def run do
    IO.puts("WebSockAdapter exists? #{Code.ensure_loaded?(WebSockAdapter)}")
  end
end
TestWebSock.run()
