Connection
==========

`Connection` behaviour for connection processes. The API is superset of the
GenServer API. There are 2 additional callbacks `connect/2` and `disconnect/2`:

```elixir
  @callback init(any) ::
    {:ok, any} | {:ok, any, timeout | :hibernate} |
    {:connect, any, any} |
    {:backoff, timeout, any} | {:backoff, timeout, any, timeout | :hibernate} |
    :ignore | {:stop, any}

  @callback connect(any, any) ::
    {:ok, any} | {:ok, any, timeout | :hibernate} |
    {:backoff, timeout, any} | {:backoff, timeout, any, timeout | :hibernate} |
    {:stop, any, any}

  @callback disconnect(any, any) ::
    {:connect, any, any} |
    {:backoff, timeout, any} | {:backoff, timeout, any, timeout | :hibernate} |
    {:noconnect, any} | {:noconnect, any, timeout | :hibernate}
    {:stop, any, any}

  @callback handle_call(any, {pid, any}, any) ::
    {:reply, any, any} | {:reply, any, any, timeout | :hibernate} |
    {:noreply, any} | {:noreply, any, timeout | :hibernate} |
    {:disconnect | :connect, any, any} |
    {:disconnect | :connect, any, any, any} |
    {:stop, any, any} | {:stop, any, any, any}

  @callback handle_cast(any, any) ::
    {:noreply, any} | {:noreply, any, timeout | :hibernate} |
    {:disconnect | :connect, any, any} |
    {:stop, any, any}

  @callback handle_info(any, any) ::
    {:noreply, any} | {:noreply, any, timeout | :hibernate} |
    {:disconnect | :connect, any, any} |
    {:stop, any, any}

  @callback code_change(any, any, any) :: {:ok, any}

  @callback terminate(any, any) :: any
```
There is an example of a simple TCP connection process in
`examples/tcp_connection/`.


## License

Copyright 2015 James Fish

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
