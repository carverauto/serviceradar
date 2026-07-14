# Environment for compiling all executables to benchmark
FROM docker.io/library/alpine:edge AS builder

# Update the system and install dependencies
RUN apk update --no-cache && \
    apk upgrade --no-cache && \
    apk add --no-cache curl clang18 llvm18 gcc g++ make git zlib-dev openssl-dev && \
    curl -sSf https://sh.rustup.rs | sh -s -- --profile minimal --component rust-src --default-toolchain nightly -y

WORKDIR /build

# Compile fastwebsockets
RUN source $HOME/.cargo/env && \
    git clone https://github.com/denoland/fastwebsockets.git && \
    cd fastwebsockets && \
    cargo update && \
    cargo build --release --example echo_server --features upgrade && \
    cp target/release/examples/echo_server /usr/bin/fastwebsockets && \
    cd ..

# Compile uWebSockets
RUN git clone --recursive https://github.com/uNetworking/uWebSockets.git && \
    make -C uWebSockets && \
    cp uWebSockets/EchoServer /usr/bin/uWebSockets

# Compile tokio-tungstenite
RUN source $HOME/.cargo/env && \
    git clone https://github.com/snapview/tokio-tungstenite.git && \
    cd tokio-tungstenite && \
    cargo update && \
    sed -i 's/tokio::main/tokio::main(flavor = "current_thread")/g' examples/echo-server.rs && \
    cargo build --release --example echo-server && \
    cp target/release/examples/echo-server /usr/bin/tokio-tungstenite && \
    cd ..

# Compile rust-websocket
RUN source $HOME/.cargo/env && \
    git clone https://github.com/websockets-rs/rust-websocket.git && \
    cd rust-websocket && \
    cargo update && \
    sed -i "s/tokio::runtime::Builder/tokio::runtime::current_thread::Builder/g" examples/async-autobahn-server.rs && \
    sed -i '13d' examples/async-autobahn-server.rs && \
    sed -i "s/executor.spawn/tokio::spawn/g" examples/async-autobahn-server.rs && \
    cargo build --release --no-default-features --features async --example async-autobahn-server && \
    cp target/release/examples/async-autobahn-server /usr/bin/rust-websocket && \
    cd ..

# Compile the benchmark tool
RUN cd /build/uWebSockets && \
    sed -i "5i #include <endian.h>" benchmarks/parser.cpp && \
    make -C benchmarks && \
    cp benchmarks/load_test /usr/bin/load_test

# Compile tokio-websockets
WORKDIR /build/tokio-websockets
COPY . .
RUN source $HOME/.cargo/env && \
    cargo build --release --no-default-features --features nightly,server,simd,sha1_smol --example echo_server --target x86_64-unknown-linux-musl && \
    cp target/x86_64-unknown-linux-musl/release/examples/echo_server /usr/bin/tokio-websockets && \
    cd ..

# Environment for benchmarking all executables
FROM docker.io/library/alpine:edge

RUN echo 'https://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories && \
    apk update --no-cache && \
    apk upgrade --no-cache && \
    apk add deno --no-cache

COPY --from=builder /usr/bin/fastwebsockets /usr/bin/fastwebsockets
COPY --from=builder /usr/bin/uWebSockets /usr/bin/uWebSockets
COPY --from=builder /usr/bin/tokio-tungstenite /usr/bin/tokio-tungstenite
COPY --from=builder /usr/bin/rust-websocket /usr/bin/rust-websocket
COPY --from=builder /usr/bin/tokio-websockets /usr/bin/tokio-websockets
COPY --from=builder /usr/bin/load_test /usr/bin/load_test

RUN mkdir /deno-dir && chmod 777 /deno-dir

WORKDIR /benches

ENV HOME /tmp

CMD ["deno", "run", "--allow-all", "run.js"]
