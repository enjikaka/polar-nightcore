# Nightcore Polar API - Wasmtime/WAT

This branch starts migrating the Deno API to a hand-written WAT `wasi:http` handler.

## Build and run

```sh
docker build -t nightcore-polar-wasm .
docker run --rm -p 8080:8080 nightcore-polar-wasm
```

Test:

```sh
curl http://localhost:8080/
curl http://localhost:8080/checkout
curl 'http://localhost:8080/validate?key=test'
curl 'http://localhost:8080/use?key=test'
```

## Current status

`nightcore-api.wat` implements the HTTP routing surface:

- `GET /`
- `GET /checkout`
- `GET /validate?key=...`
- `GET /use?key=...`

The WAT handler also sets CORS and content-type headers and handles `OPTIONS` preflight.

The Polar integration is not implemented yet. The old Deno service used the Polar SDK; in WAT we need to implement outgoing HTTPS requests through `wasi:http` imports and manually parse the returned JSON, or provide a host shim that performs Polar calls for the guest.
