#!/usr/bin/bash
podman run --rm -it -v $(pwd)/autobahn/config:/config -v $(pwd)/autobahn/reports:/reports -p 9001:9001 --security-opt label=disable --name autobahn crossbario/autobahn-testsuite
