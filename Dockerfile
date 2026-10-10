FROM debian:bookworm-slim AS build

ARG WASMTIME_VERSION=39.0.0
ARG WASM_TOOLS_VERSION=1.261.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils gzip tar \
  && rm -rf /var/lib/apt/lists/* \
  && arch="$(uname -m)" \
  && case "$arch" in \
    x86_64) target="x86_64-linux" ;; \
    aarch64|arm64) target="aarch64-linux" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac \
  && curl -fsSL "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-${target}.tar.xz" -o /tmp/wasmtime.tar.xz \
  && tar -xJf /tmp/wasmtime.tar.xz -C /tmp \
  && mv /tmp/wasmtime-v${WASMTIME_VERSION}-${target}/wasmtime /usr/local/bin/wasmtime \
  && curl -fsSL "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-${target}.tar.gz" -o /tmp/wasm-tools.tar.gz \
  && tar -xzf /tmp/wasm-tools.tar.gz -C /tmp \
  && mv /tmp/wasm-tools-${WASM_TOOLS_VERSION}-${target}/wasm-tools /usr/local/bin/wasm-tools \
  && rm -rf /tmp/wasmtime* /tmp/wasm-tools*

WORKDIR /src
COPY nightcore-api.wat ./nightcore-api.wat
COPY wit/nightcore.wit ./nightcore.wit
RUN curl -fsSL https://github.com/WebAssembly/wasi-http/archive/refs/tags/v0.2.8.tar.gz -o /tmp/wasi-http.tar.gz \
  && tar -xzf /tmp/wasi-http.tar.gz -C /tmp \
  && cp nightcore.wit /tmp/wasi-http-0.2.8/wit/nightcore.wit \
  && wasm-tools parse nightcore-api.wat -o nightcore-api.core.wasm \
  && wasm-tools component embed /tmp/wasi-http-0.2.8/wit nightcore-api.core.wasm \
      --world wasi:http/nightcore --emit-canonical-names -o nightcore-api.embed.wasm \
  && wasm-tools component new nightcore-api.embed.wasm -o nightcore-api.wasm

FROM debian:bookworm-slim
ARG WASMTIME_VERSION=39.0.0
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
  && rm -rf /var/lib/apt/lists/* \
  && arch="$(uname -m)" \
  && case "$arch" in \
    x86_64) target="x86_64-linux" ;; \
    aarch64|arm64) target="aarch64-linux" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac \
  && curl -fsSL "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-${target}.tar.xz" -o /tmp/wasmtime.tar.xz \
  && tar -xJf /tmp/wasmtime.tar.xz -C /tmp \
  && mv /tmp/wasmtime-v${WASMTIME_VERSION}-${target}/wasmtime /usr/local/bin/wasmtime \
  && rm -rf /tmp/wasmtime*

WORKDIR /app
COPY --from=build /src/nightcore-api.wasm ./nightcore-api.wasm
EXPOSE 8080
CMD ["wasmtime", "serve", "-S", "cli,inherit-env", "--addr", "0.0.0.0:8080", "/app/nightcore-api.wasm"]
