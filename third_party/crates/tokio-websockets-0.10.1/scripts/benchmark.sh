#!/usr/bin/env sh
podman build -t bench:latest -f benches/Dockerfile .
podman run \
    --rm \
    -it \
    --privileged \
    --ulimit=host \
    --ipc=host \
    --cgroups=disabled \
    --pids-limit -1 \
    --name bench \
    --security-opt label=disable \
    --userns=keep-id \
    -v $(pwd)/benches:/benches \
    bench:latest
