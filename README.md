# Nightcore Polar API - Wasmtime/WAT

The Nightcore Polar service (formerly Deno) as a hand-written WAT `wasi:http`
component, run with `wasmtime serve` in Docker.

## Build and run

```sh
docker build -t nightcore-polar-wasm .

# production
docker run --rm -p 8080:8080 --env-file .env.production nightcore-polar-wasm

# sandbox (used when the request Origin contains localhost:1337)
docker run --rm -p 8080:8080 --env-file .env.sandbox nightcore-polar-wasm
```

Env vars (must be set in the container / Dokku config):
`POLAR_ACCESS_TOKEN`, `POLAR_PRODUCT_ID`, `POLAR_ORGANIZATION_ID`, and the same
prefixed with `SANDBOX_` for sandbox. The entrypoint passes only those six via
`wasmtime serve --env NAME` (no blanket `inherit-env`). Instances are reused
across up to 128 requests (`--max-instance-reuse-count 128`).

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
- `hello-world.wat` - minimal reference example.
