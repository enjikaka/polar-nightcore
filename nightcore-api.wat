;; nightcore-api.wat - wasi:http handler written by hand.
;; Routing skeleton for Nightcore Polar API.
;;
;; Implemented routes:
;;   GET /                 -> welcome text
;;   GET /checkout         -> 501 JSON placeholder
;;   GET /validate?key=... -> 501 JSON placeholder
;;   GET /use?key=...      -> 501 JSON placeholder
;;   everything else       -> 404
;;
;; NOTE: The former Deno API talks to Polar over HTTPS. That requires
;; wasi:http outgoing requests, JSON parsing, and secret/env handling. This
;; hand-written WAT file currently provides the HTTP server/routing surface;
;; Polar integration should be added either through outgoing-handler imports
;; or a small host shim.

(module
  ;; ---- wasi:http/types ----
  (import "cm32p2|wasi:http/types@0.2" "[constructor]fields"
    (func $fields_new (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[constructor]outgoing-response"
    (func $resp_new (param i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]fields.append"
    (func $fields_append (param i32 i32 i32 i32 i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-response.set-status-code"
    (func $resp_set_status (param i32 i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-response.body"
    (func $resp_body (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-body.write"
    (func $body_write (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[static]outgoing-body.finish"
    (func $body_finish (param i32 i32 i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[static]response-outparam.set"
    (func $outparam_set (param i32 i32 i32 i32 i64 i32 i32 i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-request.method"
    (func $req_method (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-request.path-with-query"
    (func $req_path (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "incoming-request_drop"
    (func $req_drop (param i32)))

  ;; ---- wasi:io/streams ----
  (import "cm32p2|wasi:io/streams@0.2" "[method]output-stream.blocking-write-and-flush"
    (func $stream_write (param i32 i32 i32 i32)))
  (import "cm32p2|wasi:io/streams@0.2" "output-stream_drop"
    (func $stream_drop (param i32)))

  (memory (export "cm32p2_memory") 1)

  ;; Static response bodies.
  (data (i32.const 128) "Welcome to the Nightcore.app Polar service on Wasmtime.")
  (data (i32.const 256) "{\"message\":\"Polar checkout is not implemented in WAT yet\"}")
  (data (i32.const 384) "{\"valid\":false,\"limitUsage\":null,\"usage\":null,\"message\":\"Polar validation is not implemented in WAT yet\"}")
  (data (i32.const 640) "{\"valid\":false,\"message\":\"Polar usage increment is not implemented in WAT yet\"}")
  (data (i32.const 896) "not found")
  (data (i32.const 960) "")

  ;; Header names/values.
  (data (i32.const 1000) "content-type")
  (data (i32.const 1024) "text/plain; charset=utf-8")
  (data (i32.const 1056) "application/json; charset=utf-8")
  (data (i32.const 1104) "access-control-allow-origin")
  (data (i32.const 1136) "*")
  (data (i32.const 1152) "access-control-allow-methods")
  (data (i32.const 1184) "GET, OPTIONS")
  (data (i32.const 1216) "access-control-allow-headers")
  (data (i32.const 1248) "content-type")

  (global $heap (mut i32) (i32.const 2048))

  ;; Canonical ABI allocator. A bump allocator that never frees.
  (func (export "cm32p2_realloc")
    (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32)
    (result i32)
    (local $ptr i32)
    (local.set $ptr
      (i32.and
        (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
        (i32.xor (i32.sub (local.get $align) (i32.const 1)) (i32.const -1))))
    (global.set $heap (i32.add (local.get $ptr) (local.get $new_size)))
    (if (i32.gt_u (global.get $heap) (i32.const 65536))
      (then unreachable))
    (if (local.get $old)
      (then
        (memory.copy
          (local.get $ptr)
          (local.get $old)
          (select
            (local.get $old_size)
            (local.get $new_size)
            (i32.lt_u (local.get $old_size) (local.get $new_size))))))
    (local.get $ptr))

  ;; Match exactly "/".
  (func $is_root (param $p i32) (param $n i32) (result i32)
    (i32.and
      (i32.eq (local.get $n) (i32.const 1))
      (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x2f))))

  ;; Returns 1 if path is the exact route or starts with route + '?'.
  ;; route: /checkout, length 9
  (func $is_checkout (param $p i32) (param $n i32) (result i32)
    (if (i32.lt_u (local.get $n) (i32.const 9)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load (local.get $p)) (i32.const 0x6568632f)) (then (return (i32.const 0)))) ;; /che
    (if (i32.ne (i32.load offset=4 (local.get $p)) (i32.const 0x756f6b63)) (then (return (i32.const 0)))) ;; ckou
    (if (i32.ne (i32.load8_u offset=8 (local.get $p)) (i32.const 0x74)) (then (return (i32.const 0)))) ;; t
    (if (i32.eq (local.get $n) (i32.const 9)) (then (return (i32.const 1))))
    (i32.eq (i32.load8_u offset=9 (local.get $p)) (i32.const 0x3f)))

  ;; route: /validate, length 9
  (func $is_validate (param $p i32) (param $n i32) (result i32)
    (if (i32.lt_u (local.get $n) (i32.const 9)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load (local.get $p)) (i32.const 0x6c61762f)) (then (return (i32.const 0)))) ;; /val
    (if (i32.ne (i32.load offset=4 (local.get $p)) (i32.const 0x74616469)) (then (return (i32.const 0)))) ;; idat
    (if (i32.ne (i32.load8_u offset=8 (local.get $p)) (i32.const 0x65)) (then (return (i32.const 0)))) ;; e
    (if (i32.eq (local.get $n) (i32.const 9)) (then (return (i32.const 1))))
    (i32.eq (i32.load8_u offset=9 (local.get $p)) (i32.const 0x3f)))

  ;; route: /use, length 4
  (func $is_use (param $p i32) (param $n i32) (result i32)
    (if (i32.lt_u (local.get $n) (i32.const 4)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load (local.get $p)) (i32.const 0x6573752f)) (then (return (i32.const 0)))) ;; /use
    (if (i32.eq (local.get $n) (i32.const 4)) (then (return (i32.const 1))))
    (i32.eq (i32.load8_u offset=4 (local.get $p)) (i32.const 0x3f)))

  ;; handle: func(request: incoming-request, response-out: response-outparam)
  (func (export "cm32p2|wasi:http/incoming-handler@0.2|handle")
    (param $req i32) (param $out i32)
    (local $path i32) (local $len i32) (local $method i32)
    (local $status i32) (local $msg i32) (local $msg_len i32) (local $is_json i32)
    (local $resp i32) (local $fields i32) (local $body i32) (local $stream i32)

    ;; Read method. method variant at 32: tag 0=get, 6=options.
    (call $req_method (local.get $req) (i32.const 32))
    (local.set $method (i32.load (i32.const 32)))

    ;; Read path-with-query. option<string> at 16: tag, pointer, length.
    (call $req_path (local.get $req) (i32.const 16))
    (if (i32.load8_u (i32.const 16))
      (then
        (local.set $path (i32.load (i32.const 20)))
        (local.set $len (i32.load (i32.const 24)))))
    (call $req_drop (local.get $req))

    ;; Default 404.
    (local.set $status (i32.const 404))
    (local.set $msg (i32.const 896))
    (local.set $msg_len (i32.const 9))
    (local.set $is_json (i32.const 0))

    (if (call $is_root (local.get $path) (local.get $len))
      (then
        (local.set $status (i32.const 200))
        (local.set $msg (i32.const 128))
        (local.set $msg_len (i32.const 55))))

    (if (call $is_checkout (local.get $path) (local.get $len))
      (then
        (local.set $status (i32.const 501))
        (local.set $msg (i32.const 256))
        (local.set $msg_len (i32.const 58))
        (local.set $is_json (i32.const 1))))

    (if (call $is_validate (local.get $path) (local.get $len))
      (then
        (local.set $status (i32.const 501))
        (local.set $msg (i32.const 384))
        (local.set $msg_len (i32.const 105))
        (local.set $is_json (i32.const 1))))

    (if (call $is_use (local.get $path) (local.get $len))
      (then
        (local.set $status (i32.const 501))
        (local.set $msg (i32.const 640))
        (local.set $msg_len (i32.const 79))
        (local.set $is_json (i32.const 1))))

    ;; OPTIONS preflight.
    (if (i32.eq (local.get $method) (i32.const 6))
      (then
        (local.set $status (i32.const 204))
        (local.set $msg (i32.const 960))
        (local.set $msg_len (i32.const 0))
        (local.set $is_json (i32.const 0))))

    ;; Build response headers first; outgoing-response constructor takes ownership.
    (local.set $fields (call $fields_new))

    ;; CORS headers.
    (call $fields_append (local.get $fields) (i32.const 1104) (i32.const 27) (i32.const 1136) (i32.const 1) (i32.const 16))
    (call $fields_append (local.get $fields) (i32.const 1152) (i32.const 28) (i32.const 1184) (i32.const 12) (i32.const 16))
    (call $fields_append (local.get $fields) (i32.const 1216) (i32.const 28) (i32.const 1248) (i32.const 12) (i32.const 16))

    ;; Content-Type.
    (if (local.get $is_json)
      (then
        (call $fields_append (local.get $fields) (i32.const 1000) (i32.const 12) (i32.const 1056) (i32.const 31) (i32.const 16)))
      (else
        (call $fields_append (local.get $fields) (i32.const 1000) (i32.const 12) (i32.const 1024) (i32.const 25) (i32.const 16))))

    (local.set $resp (call $resp_new (local.get $fields)))
    (drop (call $resp_set_status (local.get $resp) (local.get $status)))

    ;; result<outgoing-body>: tag at 16, handle at 20.
    (call $resp_body (local.get $resp) (i32.const 16))
    (local.set $body (i32.load (i32.const 20)))

    ;; Hand response to host.
    (call $outparam_set
      (local.get $out)
      (i32.const 0)
      (local.get $resp)
      (i32.const 0) (i64.const 0)
      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))

    ;; Write body.
    (call $body_write (local.get $body) (i32.const 16))
    (local.set $stream (i32.load (i32.const 20)))
    (call $stream_write
      (local.get $stream) (local.get $msg) (local.get $msg_len) (i32.const 16))
    (call $stream_drop (local.get $stream))

    ;; Finish body. No trailers.
    (call $body_finish
      (local.get $body) (i32.const 0) (i32.const 0) (i32.const 16))))
