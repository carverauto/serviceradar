#!/usr/bin/bash
podman run --rm -it -v $(pwd)/autobahn/config:/config -v $(pwd)/autobahn/reports:/reports --net host --security-opt label=disable --name autobahn crossbario/autobahn-testsuite wstest -m fuzzingclient -s /config/fuzzingclient.json
