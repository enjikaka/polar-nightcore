;; hello.wat - wasi:http handler written by hand.
;; GET /hello -> 200 "world". Everything else -> 404 "not found".
;;
;; Memory map (64 KiB, one page):
;;   16..80     scratch area for return values from the host
;;   128        "world"      (5 bytes)
;;   144        "not found"  (9 bytes)
;;   1024..     bump heap for cabi_realloc (the host writes the path here)

(module
  ;; ---- wasi:http/types ----
  (import "cm32p2|wasi:http/types@0.2" "[constructor]fields"
    (func $fields_new (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[constructor]outgoing-response"
    (func $resp_new (param i32) (result i32)))
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

  (data (i32.const 128) "world")
  (data (i32.const 144) "not found")

  (global $heap (mut i32) (i32.const 1024))

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

  ;; Returns 1 if the path is "/hello" or starts with "/hello?".
  (func $is_hello (param $p i32) (param $n i32) (result i32)
    (if (i32.lt_u (local.get $n) (i32.const 6))
      (then (return (i32.const 0))))
    ;; bytes "/hel" as a little-endian i32
    (if (i32.ne (i32.load (local.get $p)) (i32.const 0x6c65682f))
      (then (return (i32.const 0))))
    ;; bytes "lo" as a little-endian i16
    (if (i32.ne (i32.load16_u offset=4 (local.get $p)) (i32.const 0x6f6c))
      (then (return (i32.const 0))))
    (if (i32.eq (local.get $n) (i32.const 6))
      (then (return (i32.const 1))))
    ;; the next byte must be '?'
    (i32.eq (i32.load8_u offset=6 (local.get $p)) (i32.const 0x3f)))

  ;; handle: func(request: incoming-request, response-out: response-outparam)
  (func (export "cm32p2|wasi:http/incoming-handler@0.2|handle")
    (param $req i32) (param $out i32)
    (local $path i32) (local $len i32)
    (local $status i32) (local $msg i32) (local $msg_len i32)
    (local $resp i32) (local $body i32) (local $stream i32)

    ;; 1. Read the path. option<string> lands at 16:
    ;;    tag at 16, pointer at 20, length at 24.
    (call $req_path (local.get $req) (i32.const 16))
    (if (i32.load8_u (i32.const 16))
      (then
        (local.set $path (i32.load (i32.const 20)))
        (local.set $len (i32.load (i32.const 24)))))
    (call $req_drop (local.get $req))

    ;; 2. Route.
    (if (call $is_hello (local.get $path) (local.get $len))
      (then
        (local.set $status (i32.const 200))
        (local.set $msg (i32.const 128))
        (local.set $msg_len (i32.const 5)))
      (else
        (local.set $status (i32.const 404))
        (local.set $msg (i32.const 144))
        (local.set $msg_len (i32.const 9))))

    ;; 3. Build the response. The constructor takes ownership of the headers.
    (local.set $resp (call $resp_new (call $fields_new)))
    (drop (call $resp_set_status (local.get $resp) (local.get $status)))

    ;; Get the body handle. result<outgoing-body>: tag at 16, handle at 20.
    (call $resp_body (local.get $resp) (i32.const 16))
    (local.set $body (i32.load (i32.const 20)))

    ;; 4. Hand the response to the host: ok(resp).
    ;;    The trailing zeros pad the flattened error-code variant.
    (call $outparam_set
      (local.get $out)
      (i32.const 0)            ;; result tag: ok
      (local.get $resp)        ;; the response handle
      (i32.const 0) (i64.const 0)
      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))

    ;; 5. Write the body. result<output-stream>: tag at 16, handle at 20.
    (call $body_write (local.get $body) (i32.const 16))
    (local.set $stream (i32.load (i32.const 20)))
    (call $stream_write
      (local.get $stream) (local.get $msg) (local.get $msg_len) (i32.const 16))
    (call $stream_drop (local.get $stream))

    ;; 6. Finish the body. No trailers: option tag 0, payload 0.
    (call $body_finish
      (local.get $body) (i32.const 0) (i32.const 0) (i32.const 16))))
