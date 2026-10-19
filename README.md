# Nightcore Polar API - Wasmtime/WAT

The Nightcore Polar service (formerly Deno) as a hand-written WAT `wasi:http`
component, run with `wasmtime serve` in Docker.

## Build and run (production / Dokku)

```sh
docker build -t nightcore-polar-wasm .

docker run --rm -p 8080:8080 --env-file .env.production nightcore-polar-wasm
```

**Dokku / production env vars** (required in the container config):

- `POLAR_ACCESS_TOKEN`
- `POLAR_PRODUCT_ID`
- `POLAR_ORGANIZATION_ID`

The image entrypoint passes only those three into the guest via
`wasmtime serve --env NAME` (no blanket `inherit-env`, no `SANDBOX_*`).
Instances are reused across up to 128 requests (`--max-instance-reuse-count 128`).

The image AOT-compiles the component to `nightcore-api.cwasm` during `docker build`
with the **same** `wasmtime` binary that later runs `serve --allow-precompiled`.
Do not copy a `.cwasm` built by a different Wasmtime version or CPU architecture.

## Local sandbox (optional)

Requests whose `Origin` contains `localhost:1337` use Polar **sandbox** credentials
(`SANDBOX_POLAR_ACCESS_TOKEN`, `SANDBOX_POLAR_PRODUCT_ID`, `SANDBOX_POLAR_ORGANIZATION_ID`).
Those vars are **not** wired in the Docker ENTRYPOINT (Dokku should not set them).

For local testing, pass them explicitly when serving outside the production entrypoint,
for example after building the component/`cwasm` yourself:

```sh
wasmtime serve --allow-precompiled -S cli \
  --env POLAR_ACCESS_TOKEN \
  --env POLAR_PRODUCT_ID \
  --env POLAR_ORGANIZATION_ID \
  --env SANDBOX_POLAR_ACCESS_TOKEN \
  --env SANDBOX_POLAR_PRODUCT_ID \
  --env SANDBOX_POLAR_ORGANIZATION_ID \
  --max-instance-reuse-count 128 \
  --max-instance-concurrent-reuse-count 1 \
  --addr 0.0.0.0:8080 \
  ./nightcore-api.cwasm
```

(Export the six values in your shell / `.env` first; `--env NAME` inherits from the host.)

## Routes

| Route | Result |
| --- | --- |
| `GET /` | welcome text |
| `GET /checkout` | creates a Polar checkout -> `{"url": "..."}` |
| `GET /validate?key=...` | `{"valid", "limitUsage", "usage"}` |
| `GET /use?key=...` | validates and increments usage -> `{"valid"}` (400 if invalid) |
| `OPTIONS *` | CORS preflight (204) |

CORS headers are only sent for `https://nightcore.app`,
`https://nightcore--polar.deno.dev` and `http://localhost:1337`.

## Layout

- `nightcore-api.wat` - the service. Polar calls go through
  `wasi:http/outgoing-handler`; JSON is built/parsed by hand.
- `wit/nightcore.wit` - world = `wasi:http/proxy` + `wasi:cli/environment`.
- `tools/gen-strings.py` - generates the string table (data segments + `$S_*`/`$L_*`
  globals) at the top of the WAT file. Re-run and paste if you add strings.
