;; nightcore-api.wat - wasi:http handler written by hand.
;;
;; Port of the Deno service to a hand-written WAT component.
;;
;;   GET /                 -> welcome text
;;   GET /checkout         -> creates a Polar checkout, returns {"url": ...}
;;   GET /validate?key=..  -> validates a license key
;;   GET /use?key=..       -> validates + increments usage of a license key
;;
;; Environment (passed with `wasmtime serve --env`):
;;   POLAR_ACCESS_TOKEN, POLAR_PRODUCT_ID, POLAR_ORGANIZATION_ID
;;   SANDBOX_POLAR_ACCESS_TOKEN, SANDBOX_POLAR_PRODUCT_ID, SANDBOX_POLAR_ORGANIZATION_ID
;; Requests with an Origin containing "localhost:1337" use the sandbox.
;;
;; Memory map (16 pages = 1 MiB):
;;   0x0000..0x03FF  scratch / return areas
;;   0x0400..0x1FFF  string table (generated, see below)
;;   0x2000..0x27FF  outgoing request body
;;   0x2800..0x2FFF  our JSON response body
;;   0x3000..0x3FFF  "Bearer <token>"
;;   0x4000..0xBFFF  Polar response body (32 KiB)
;;   0x10000..       bump heap for cabi_realloc

(module
  ;; ---- wasi:http/types ----
  (import "cm32p2|wasi:http/types@0.2" "[constructor]fields"
    (func $fields_new (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]fields.append"
    (func $fields_append (param i32 i32 i32 i32 i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]fields.get"
    (func $fields_get (param i32 i32 i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "fields_drop"
    (func $fields_drop (param i32)))
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
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-request.method"
    (func $req_method (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-request.path-with-query"
    (func $req_path (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-request.headers"
    (func $req_headers (param i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "incoming-request_drop"
    (func $req_drop (param i32)))

  ;; outgoing requests
  (import "cm32p2|wasi:http/types@0.2" "[constructor]outgoing-request"
    (func $oreq_new (param i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-request.body"
    (func $oreq_body (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-request.set-method"
    (func $oreq_set_method (param i32 i32 i32 i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-request.set-scheme"
    (func $oreq_set_scheme (param i32 i32 i32 i32 i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-request.set-authority"
    (func $oreq_set_authority (param i32 i32 i32 i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]outgoing-request.set-path-with-query"
    (func $oreq_set_path (param i32 i32 i32 i32) (result i32)))
  (import "cm32p2|wasi:http/outgoing-handler@0.2" "handle"
    (func $outgoing_handle (param i32 i32 i32 i32)))

  ;; incoming responses
  (import "cm32p2|wasi:http/types@0.2" "[method]future-incoming-response.subscribe"
    (func $fut_subscribe (param i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]future-incoming-response.get"
    (func $fut_get (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "future-incoming-response_drop"
    (func $fut_drop (param i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-response.status"
    (func $iresp_status (param i32) (result i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-response.consume"
    (func $iresp_consume (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "incoming-response_drop"
    (func $iresp_drop (param i32)))
  (import "cm32p2|wasi:http/types@0.2" "[method]incoming-body.stream"
    (func $ibody_stream (param i32 i32)))
  (import "cm32p2|wasi:http/types@0.2" "incoming-body_drop"
    (func $ibody_drop (param i32)))

  ;; ---- wasi:io ----
  (import "cm32p2|wasi:io/streams@0.2" "[method]output-stream.blocking-write-and-flush"
    (func $stream_write (param i32 i32 i32 i32)))
  (import "cm32p2|wasi:io/streams@0.2" "output-stream_drop"
    (func $stream_drop (param i32)))
  (import "cm32p2|wasi:io/streams@0.2" "[method]input-stream.blocking-read"
    (func $istream_read (param i32 i64 i32)))
  (import "cm32p2|wasi:io/streams@0.2" "input-stream_drop"
    (func $istream_drop (param i32)))
  (import "cm32p2|wasi:io/poll@0.2" "[method]pollable.block"
    (func $pollable_block (param i32)))
  (import "cm32p2|wasi:io/poll@0.2" "pollable_drop"
    (func $pollable_drop (param i32)))

  ;; ---- wasi:cli ----
  (import "cm32p2|wasi:cli/environment@0.2" "get-environment"
    (func $get_environment (param i32)))

  (memory (export "cm32p2_memory") 16)

  ;; ---- string table (generated offsets) ----
    (data (i32.const 1024) "Welcome to the Nightcore.app Polar service on Wasmtime.")
    (global $S_root i32 (i32.const 1024))
    (global $L_root i32 (i32.const 55))
    (data (i32.const 1080) "not found")
    (global $S_notfound i32 (i32.const 1080))
    (global $L_notfound i32 (i32.const 9))
    (data (i32.const 1096) "Missing license key")
    (global $S_missingkey i32 (i32.const 1096))
    (global $L_missingkey i32 (i32.const 19))
    (data (i32.const 1120) "content-type")
    (global $S_h_ct i32 (i32.const 1120))
    (global $L_h_ct i32 (i32.const 12))
    (data (i32.const 1136) "text/plain; charset=utf-8")
    (global $S_ct_text i32 (i32.const 1136))
    (global $L_ct_text i32 (i32.const 25))
    (data (i32.const 1168) "application/json; charset=utf-8")
    (global $S_ct_json i32 (i32.const 1168))
    (global $L_ct_json i32 (i32.const 31))
    (data (i32.const 1200) "access-control-allow-origin")
    (global $S_h_acao i32 (i32.const 1200))
    (global $L_h_acao i32 (i32.const 27))
    (data (i32.const 1232) "access-control-allow-methods")
    (global $S_h_acam i32 (i32.const 1232))
    (global $L_h_acam i32 (i32.const 28))
    (data (i32.const 1264) "access-control-allow-headers")
    (global $S_h_acah i32 (i32.const 1264))
    (global $L_h_acah i32 (i32.const 28))
    (data (i32.const 1296) "vary")
    (global $S_h_vary i32 (i32.const 1296))
    (global $L_h_vary i32 (i32.const 4))
    (data (i32.const 1304) "GET, OPTIONS")
    (global $S_v_methods i32 (i32.const 1304))
    (global $L_v_methods i32 (i32.const 12))
    (data (i32.const 1320) "origin")
    (global $S_origin i32 (i32.const 1320))
    (global $L_origin i32 (i32.const 6))
    (data (i32.const 1328) "authorization")
    (global $S_h_auth i32 (i32.const 1328))
    (global $L_h_auth i32 (i32.const 13))
    (data (i32.const 1344) "Bearer ")
    (global $S_bearer i32 (i32.const 1344))
    (global $L_bearer i32 (i32.const 7))
    (data (i32.const 1352) "user-agent")
    (global $S_h_ua i32 (i32.const 1352))
    (global $L_h_ua i32 (i32.const 10))
    (data (i32.const 1368) "nightcore-polar-wasm")
    (global $S_v_ua i32 (i32.const 1368))
    (global $L_v_ua i32 (i32.const 20))
    (data (i32.const 1392) "https://nightcore.app")
    (global $S_o1 i32 (i32.const 1392))
    (global $L_o1 i32 (i32.const 21))
    (data (i32.const 1416) "https://nightcore--polar.deno.dev")
    (global $S_o2 i32 (i32.const 1416))
    (global $L_o2 i32 (i32.const 33))
    (data (i32.const 1456) "http://localhost:1337")
    (global $S_o3 i32 (i32.const 1456))
    (global $L_o3 i32 (i32.const 21))
    (data (i32.const 1480) "localhost:1337")
    (global $S_localhost i32 (i32.const 1480))
    (global $L_localhost i32 (i32.const 14))
    (data (i32.const 1496) "api.polar.sh")
    (global $S_host_prod i32 (i32.const 1496))
    (global $L_host_prod i32 (i32.const 12))
    (data (i32.const 1512) "sandbox-api.polar.sh")
    (global $S_host_sbx i32 (i32.const 1512))
    (global $L_host_sbx i32 (i32.const 20))
    (data (i32.const 1536) "/v1/checkouts/")
    (global $S_p_checkout i32 (i32.const 1536))
    (global $L_p_checkout i32 (i32.const 14))
    (data (i32.const 1552) "/v1/customer-portal/license-keys/validate")
    (global $S_p_validate i32 (i32.const 1552))
    (global $L_p_validate i32 (i32.const 41))
    (data (i32.const 1600) "/")
    (global $S_r_root i32 (i32.const 1600))
    (global $L_r_root i32 (i32.const 1))
    (data (i32.const 1608) "/checkout")
    (global $S_r_checkout i32 (i32.const 1608))
    (global $L_r_checkout i32 (i32.const 9))
    (data (i32.const 1624) "/validate")
    (global $S_r_validate i32 (i32.const 1624))
    (global $L_r_validate i32 (i32.const 9))
    (data (i32.const 1640) "/use")
    (global $S_r_use i32 (i32.const 1640))
    (global $L_r_use i32 (i32.const 4))
    (data (i32.const 1648) "key=")
    (global $S_key_eq i32 (i32.const 1648))
    (global $L_key_eq i32 (i32.const 4))
    (data (i32.const 1656) "SANDBOX_")
    (global $S_e_sandbox i32 (i32.const 1656))
    (global $L_e_sandbox i32 (i32.const 8))
    (data (i32.const 1664) "POLAR_ACCESS_TOKEN")
    (global $S_e_token i32 (i32.const 1664))
    (global $L_e_token i32 (i32.const 18))
    (data (i32.const 1688) "POLAR_PRODUCT_ID")
    (global $S_e_product i32 (i32.const 1688))
    (global $L_e_product i32 (i32.const 16))
    (data (i32.const 1704) "POLAR_ORGANIZATION_ID")
    (global $S_e_org i32 (i32.const 1704))
    (global $L_e_org i32 (i32.const 21))
    (data (i32.const 1728) "{\"products\":[\"")
    (global $S_j_ck_pre i32 (i32.const 1728))
    (global $L_j_ck_pre i32 (i32.const 14))
    (data (i32.const 1744) "\"]}")
    (global $S_j_ck_post i32 (i32.const 1744))
    (global $L_j_ck_post i32 (i32.const 3))
    (data (i32.const 1752) "{\"key\":\"")
    (global $S_j_key_pre i32 (i32.const 1752))
    (global $L_j_key_pre i32 (i32.const 8))
    (data (i32.const 1760) "\",\"organization_id\":\"")
    (global $S_j_org i32 (i32.const 1760))
    (global $L_j_org i32 (i32.const 21))
    (data (i32.const 1784) "\"}")
    (global $S_j_end i32 (i32.const 1784))
    (global $L_j_end i32 (i32.const 2))
    (data (i32.const 1792) "\",\"increment_usage\":1}")
    (global $S_j_inc i32 (i32.const 1792))
    (global $L_j_inc i32 (i32.const 22))
    (data (i32.const 1816) "\"url\":\"")
    (global $S_n_url i32 (i32.const 1816))
    (global $L_n_url i32 (i32.const 7))
    (data (i32.const 1824) "\"status\":\"")
    (global $S_n_status i32 (i32.const 1824))
    (global $L_n_status i32 (i32.const 10))
    (data (i32.const 1840) "granted")
    (global $S_granted i32 (i32.const 1840))
    (global $L_granted i32 (i32.const 7))
    (data (i32.const 1848) "\"limit_usage\":")
    (global $S_n_limit i32 (i32.const 1848))
    (global $L_n_limit i32 (i32.const 14))
    (data (i32.const 1864) "\"usage\":")
    (global $S_n_usage i32 (i32.const 1864))
    (global $L_n_usage i32 (i32.const 8))
    (data (i32.const 1872) "null")
    (global $S_null i32 (i32.const 1872))
    (global $L_null i32 (i32.const 4))
    (data (i32.const 1880) "{\"url\":\"")
    (global $S_o_url_pre i32 (i32.const 1880))
    (global $L_o_url_pre i32 (i32.const 8))
    (data (i32.const 1888) "{\"valid\":true,\"limitUsage\":")
    (global $S_o_valid_t i32 (i32.const 1888))
    (global $L_o_valid_t i32 (i32.const 27))
    (data (i32.const 1920) "{\"valid\":false,\"limitUsage\":")
    (global $S_o_valid_f i32 (i32.const 1920))
    (global $L_o_valid_f i32 (i32.const 28))
    (data (i32.const 1952) ",\"usage\":")
    (global $S_o_usage i32 (i32.const 1952))
    (global $L_o_usage i32 (i32.const 9))
    (data (i32.const 1968) "}")
    (global $S_o_close i32 (i32.const 1968))
    (global $L_o_close i32 (i32.const 1))
    (data (i32.const 1976) "{\"valid\":true}")
    (global $S_o_use_t i32 (i32.const 1976))
    (global $L_o_use_t i32 (i32.const 14))
    (data (i32.const 1992) "{\"valid\":false}")
    (global $S_o_use_f i32 (i32.const 1992))
    (global $L_o_use_f i32 (i32.const 15))
    (data (i32.const 2008) "{\"message\":\"Licence key is not valid\"}")
    (global $S_err_use i32 (i32.const 2008))
    (global $L_err_use i32 (i32.const 38))
    (data (i32.const 2048) "{\"message\":\"Missing environment variable\"}")
    (global $S_err_env i32 (i32.const 2048))
    (global $L_err_env i32 (i32.const 42))
    (data (i32.const 2096) "{\"message\":\"Polar request failed\"}")
    (global $S_err_up i32 (i32.const 2096))
    (global $L_err_up i32 (i32.const 34))

  ;; ---- state ----
  (global $heap (mut i32) (i32.const 65536))
  (global $sandbox (mut i32) (i32.const 0))
  (global $origin_ptr (mut i32) (i32.const 0))
  (global $origin_len (mut i32) (i32.const 0))
  (global $env_ptr (mut i32) (i32.const 0))
  (global $env_n (mut i32) (i32.const 0))
  (global $resp_len (mut i32) (i32.const 0))
  ;; result of a route handler
  (global $r_status (mut i32) (i32.const 404))
  (global $r_ptr (mut i32) (i32.const 0))
  (global $r_len (mut i32) (i32.const 0))
  (global $r_json (mut i32) (i32.const 0))

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
    (if (i32.gt_u (global.get $heap) (i32.const 1048576))
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

  ;; ======================= helpers =======================

  ;; memcmp-style equality.
  (func $memeq (param $a i32) (param $b i32) (param $n i32) (result i32)
    (local $i i32)
    (loop $l
      (if (i32.ge_u (local.get $i) (local.get $n))
        (then (return (i32.const 1))))
      (if (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i)))
                  (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))
    (i32.const 0))

  ;; Copy n bytes, return dst + n.
  (func $put (param $dst i32) (param $src i32) (param $n i32) (result i32)
    (memory.copy (local.get $dst) (local.get $src) (local.get $n))
    (i32.add (local.get $dst) (local.get $n)))

  ;; Write unsigned decimal, return new end.
  (func $put_u32 (param $dst i32) (param $v i32) (result i32)
    (local $digits i32) (local $t i32) (local $p i32)
    (local.set $digits (i32.const 1))
    (local.set $t (local.get $v))
    (block $done
      (loop $count
        (br_if $done (i32.lt_u (local.get $t) (i32.const 10)))
        (local.set $t (i32.div_u (local.get $t) (i32.const 10)))
        (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
        (br $count)))
    (local.set $p (i32.add (local.get $dst) (local.get $digits)))
    (local.set $t (local.get $v))
    (loop $w
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p)
        (i32.add (i32.const 48) (i32.rem_u (local.get $t) (i32.const 10))))
      (local.set $t (i32.div_u (local.get $t) (i32.const 10)))
      (br_if $w (i32.ne (local.get $p) (local.get $dst))))
    (i32.add (local.get $dst) (local.get $digits)))

  ;; Find needle in haystack; returns pointer to the match or 0.
  (func $find (param $h i32) (param $hn i32) (param $nd i32) (param $nn i32) (result i32)
    (local $i i32)
    (if (i32.gt_u (local.get $nn) (local.get $hn))
      (then (return (i32.const 0))))
    (loop $l
      (if (i32.gt_u (local.get $i) (i32.sub (local.get $hn) (local.get $nn)))
        (then (return (i32.const 0))))
      (if (call $memeq (i32.add (local.get $h) (local.get $i)) (local.get $nd) (local.get $nn))
        (then (return (i32.add (local.get $h) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))
    (i32.const 0))

  ;; Route match: path == route, or path starts with route + '?'.
  (func $is_route (param $p i32) (param $n i32) (param $r i32) (param $rn i32) (result i32)
    (if (i32.lt_u (local.get $n) (local.get $rn)) (then (return (i32.const 0))))
    (if (i32.eqz (call $memeq (local.get $p) (local.get $r) (local.get $rn)))
      (then (return (i32.const 0))))
    (if (i32.eq (local.get $n) (local.get $rn)) (then (return (i32.const 1))))
    (i32.eq (i32.load8_u (i32.add (local.get $p) (local.get $rn))) (i32.const 0x3f)))

  ;; Is the Origin header exactly one of the allowed origins?
  (func $origin_allowed (result i32)
    (local $p i32) (local $n i32)
    (local.set $p (global.get $origin_ptr))
    (local.set $n (global.get $origin_len))
    (if (i32.eqz (local.get $p)) (then (return (i32.const 0))))
    (if (i32.and (i32.eq (local.get $n) (global.get $L_o1))
                 (call $memeq (local.get $p) (global.get $S_o1) (local.get $n)))
      (then (return (i32.const 1))))
    (if (i32.and (i32.eq (local.get $n) (global.get $L_o2))
                 (call $memeq (local.get $p) (global.get $S_o2) (local.get $n)))
      (then (return (i32.const 1))))
    (if (i32.and (i32.eq (local.get $n) (global.get $L_o3))
                 (call $memeq (local.get $p) (global.get $S_o3) (local.get $n)))
      (then (return (i32.const 1))))
    (i32.const 0))

  ;; Read the Origin request header into $origin_ptr/$origin_len.
  (func $read_origin (param $req i32)
    (local $fields i32) (local $list i32)
    (local.set $fields (call $req_headers (local.get $req)))
    ;; list<field-value> lands at 0x100: ptr, len. Each element is (ptr, len).
    (call $fields_get (local.get $fields) (global.get $S_origin) (global.get $L_origin) (i32.const 0x100))
    (if (i32.load (i32.const 0x104))
      (then
        (local.set $list (i32.load (i32.const 0x100)))
        (global.set $origin_ptr (i32.load (local.get $list)))
        (global.set $origin_len (i32.load offset=4 (local.get $list)))))
    (call $fields_drop (local.get $fields)))

  ;; Look up an environment variable (SANDBOX_ prefix when sandboxed).
  ;; Returns (ptr, len); ptr == 0 when missing.
  (func $getenv (param $base i32) (param $base_len i32) (result i32 i32)
    (local $d i32) (local $n i32) (local $i i32) (local $e i32)
    (local.set $d (i32.const 0x300))
    (if (global.get $sandbox)
      (then (local.set $d (call $put (local.get $d) (global.get $S_e_sandbox) (global.get $L_e_sandbox)))))
    (local.set $d (call $put (local.get $d) (local.get $base) (local.get $base_len)))
    (local.set $n (i32.sub (local.get $d) (i32.const 0x300)))
    (block $out
      (loop $l
        (br_if $out (i32.ge_u (local.get $i) (global.get $env_n)))
        (local.set $e (i32.add (global.get $env_ptr) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.eq (i32.load offset=4 (local.get $e)) (local.get $n))
          (then
            (if (call $memeq (i32.load (local.get $e)) (i32.const 0x300) (local.get $n))
              (then
                (return (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i32.const 0) (i32.const 0))

  ;; Extract the value of the `key` query parameter; returns (ptr, len), ptr 0 if absent.
  (func $query_key (param $p i32) (param $n i32) (result i32 i32)
    (local $i i32) (local $m i32) (local $idx i32) (local $s i32) (local $e i32) (local $end i32)
    (local.set $end (i32.add (local.get $p) (local.get $n)))
    (loop $l
      (local.set $m
        (call $find
          (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i))
          (global.get $S_key_eq) (global.get $L_key_eq)))
      (if (i32.eqz (local.get $m)) (then (return (i32.const 0) (i32.const 0))))
      (local.set $idx (i32.sub (local.get $m) (local.get $p)))
      (if (i32.gt_u (local.get $idx) (i32.const 0))
        (then
          (if (i32.or
                (i32.eq (i32.load8_u (i32.sub (local.get $m) (i32.const 1))) (i32.const 0x3f))
                (i32.eq (i32.load8_u (i32.sub (local.get $m) (i32.const 1))) (i32.const 0x26)))
            (then
              (local.set $s (i32.add (local.get $m) (i32.const 4)))
              (local.set $e (local.get $s))
              (block $x
                (loop $scan
                  (br_if $x (i32.ge_u (local.get $e) (local.get $end)))
                  (br_if $x (i32.eq (i32.load8_u (local.get $e)) (i32.const 0x26)))
                  (local.set $e (i32.add (local.get $e) (i32.const 1)))
                  (br $scan)))
              (return (local.get $s) (i32.sub (local.get $e) (local.get $s)))))))
      (local.set $i (i32.add (local.get $idx) (i32.const 1)))
      (br $l))
    (i32.const 0) (i32.const 0))

  ;; 1 if every byte is printable and not '"' or '\' (safe to embed in JSON).
  (func $json_safe (param $p i32) (param $n i32) (result i32)
    (local $i i32) (local $c i32)
    (loop $l
      (if (i32.ge_u (local.get $i) (local.get $n)) (then (return (i32.const 1))))
      (local.set $c (i32.load8_u (i32.add (local.get $p) (local.get $i))))
      (if (i32.or (i32.lt_u (local.get $c) (i32.const 0x20))
            (i32.or (i32.eq (local.get $c) (i32.const 0x22)) (i32.eq (local.get $c) (i32.const 0x5c))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))
    (i32.const 1))

  ;; Find `needle` in the Polar response; returns pointer just after it, or 0.
  (func $resp_find (param $nd i32) (param $nn i32) (result i32)
    (local $m i32)
    (local.set $m (call $find (i32.const 0x4000) (global.get $resp_len) (local.get $nd) (local.get $nn)))
    (if (i32.eqz (local.get $m)) (then (return (i32.const 0))))
    (i32.add (local.get $m) (local.get $nn)))

  ;; Length of a JSON string starting at p (up to the closing quote).
  (func $str_len (param $p i32) (result i32)
    (local $e i32) (local $end i32)
    (local.set $end (i32.add (i32.const 0x4000) (global.get $resp_len)))
    (local.set $e (local.get $p))
    (block $x
      (loop $l
        (br_if $x (i32.ge_u (local.get $e) (local.get $end)))
        (br_if $x (i32.eq (i32.load8_u (local.get $e)) (i32.const 0x22)))
        (local.set $e (i32.add (local.get $e) (i32.const 1)))
        (br $l)))
    (i32.sub (local.get $e) (local.get $p)))

  ;; Parse unsigned digits at p; returns (value, ok).
  (func $parse_u32 (param $p i32) (result i32 i32)
    (local $v i32) (local $c i32) (local $n i32) (local $end i32)
    (local.set $end (i32.add (i32.const 0x4000) (global.get $resp_len)))
    (loop $l
      (if (i32.lt_u (local.get $p) (local.get $end))
        (then
          (local.set $c (i32.load8_u (local.get $p)))
          (if (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
            (then
              (local.set $v (i32.add (i32.mul (local.get $v) (i32.const 10))
                                     (i32.sub (local.get $c) (i32.const 48))))
              (local.set $n (i32.add (local.get $n) (i32.const 1)))
              (local.set $p (i32.add (local.get $p) (i32.const 1)))
              (br $l))))))
    (local.get $v) (i32.ne (local.get $n) (i32.const 0)))

  ;; Set the route result.
  (func $reply (param $status i32) (param $ptr i32) (param $len i32) (param $json i32)
    (global.set $r_status (local.get $status))
    (global.set $r_ptr (local.get $ptr))
    (global.set $r_len (local.get $len))
    (global.set $r_json (local.get $json)))

  ;; ======================= outgoing HTTP =======================

  ;; POST a JSON body to Polar. Returns the HTTP status, or 0 on transport failure.
  ;; Response body is copied to 0x4000 (length in $resp_len).
  (func $polar_post (param $path i32) (param $path_len i32) (param $body i32) (param $body_len i32)
    (result i32)
    (local $tok_ptr i32) (local $tok_len i32) (local $d i32)
    (local $fields i32) (local $req i32) (local $obody i32) (local $stream i32)
    (local $fut i32) (local $pol i32) (local $resp i32) (local $status i32)
    (local $ibody i32) (local $istream i32) (local $off i32) (local $n i32)

    (global.set $resp_len (i32.const 0))

    (call $getenv (global.get $S_e_token) (global.get $L_e_token))
    (local.set $tok_len)
    (local.set $tok_ptr)

    ;; Authorization: Bearer <token>
    (local.set $d (call $put (i32.const 0x3000) (global.get $S_bearer) (global.get $L_bearer)))
    (local.set $d (call $put (local.get $d) (local.get $tok_ptr) (local.get $tok_len)))

    (local.set $fields (call $fields_new))
    (call $fields_append (local.get $fields)
      (global.get $S_h_auth) (global.get $L_h_auth)
      (i32.const 0x3000) (i32.sub (local.get $d) (i32.const 0x3000)) (i32.const 0x40))
    (call $fields_append (local.get $fields)
      (global.get $S_h_ct) (global.get $L_h_ct)
      (global.get $S_ct_json) (global.get $L_ct_json) (i32.const 0x40))
    (call $fields_append (local.get $fields)
      (global.get $S_h_ua) (global.get $L_h_ua)
      (global.get $S_v_ua) (global.get $L_v_ua) (i32.const 0x40))

    (local.set $req (call $oreq_new (local.get $fields)))
    ;; method POST = variant tag 2
    (drop (call $oreq_set_method (local.get $req) (i32.const 2) (i32.const 0) (i32.const 0)))
    ;; scheme: some(HTTPS) = option tag 1, variant tag 1
    (drop (call $oreq_set_scheme (local.get $req) (i32.const 1) (i32.const 1) (i32.const 0) (i32.const 0)))
    (if (global.get $sandbox)
      (then
        (drop (call $oreq_set_authority (local.get $req) (i32.const 1)
                (global.get $S_host_sbx) (global.get $L_host_sbx))))
      (else
        (drop (call $oreq_set_authority (local.get $req) (i32.const 1)
                (global.get $S_host_prod) (global.get $L_host_prod)))))
    (drop (call $oreq_set_path (local.get $req) (i32.const 1) (local.get $path) (local.get $path_len)))

    ;; Body handle: result<outgoing-body>: tag at 0x40, handle at 0x44.
    (call $oreq_body (local.get $req) (i32.const 0x40))
    (local.set $obody (i32.load (i32.const 0x44)))

    ;; Send: handle(request, none) -> result<future, error-code>
    (call $outgoing_handle (local.get $req) (i32.const 0) (i32.const 0) (i32.const 0x40))
    (if (i32.load8_u (i32.const 0x40))
      (then (return (i32.const 0))))
    ;; error-code has 8-byte alignment, so the ok payload sits at 0x48.
    (local.set $fut (i32.load (i32.const 0x48)))

    ;; Write + finish the request body.
    (call $body_write (local.get $obody) (i32.const 0x40))
    (local.set $stream (i32.load (i32.const 0x44)))
    (call $stream_write (local.get $stream) (local.get $body) (local.get $body_len) (i32.const 0x40))
    (call $stream_drop (local.get $stream))
    (call $body_finish (local.get $obody) (i32.const 0) (i32.const 0) (i32.const 0x40))

    ;; Wait for the response.
    (local.set $pol (call $fut_subscribe (local.get $fut)))
    (call $pollable_block (local.get $pol))
    (call $pollable_drop (local.get $pol))

    ;; option<result<result<incoming-response, error-code>, ()>>
    ;;   option tag @0x40, outer tag @0x48, inner tag @0x50, handle @0x58
    (call $fut_get (local.get $fut) (i32.const 0x40))
    (if (i32.eqz (i32.load8_u (i32.const 0x40))) (then (return (i32.const 0))))
    (if (i32.load8_u (i32.const 0x48)) (then (return (i32.const 0))))
    (if (i32.load8_u (i32.const 0x50)) (then (return (i32.const 0))))
    (local.set $resp (i32.load (i32.const 0x58)))

    (local.set $status (call $iresp_status (local.get $resp)))

    ;; Read the body.
    (call $iresp_consume (local.get $resp) (i32.const 0x40))
    (local.set $ibody (i32.load (i32.const 0x44)))
    (call $ibody_stream (local.get $ibody) (i32.const 0x40))
    (local.set $istream (i32.load (i32.const 0x44)))
    (block $eof
      (loop $rd
        ;; result<list<u8>, stream-error>: tag @0x40, ptr @0x44, len @0x48
        (call $istream_read (local.get $istream) (i64.const 4096) (i32.const 0x40))
        (br_if $eof (i32.load8_u (i32.const 0x40)))
        (local.set $n (i32.load (i32.const 0x48)))
        (br_if $eof (i32.gt_u (i32.add (local.get $off) (local.get $n)) (i32.const 32768)))
        (memory.copy
          (i32.add (i32.const 0x4000) (local.get $off))
          (i32.load (i32.const 0x44))
          (local.get $n))
        (local.set $off (i32.add (local.get $off) (local.get $n)))
        (br $rd)))
    (global.set $resp_len (local.get $off))

    (call $istream_drop (local.get $istream))
    (call $ibody_drop (local.get $ibody))
    (call $iresp_drop (local.get $resp))
    (call $fut_drop (local.get $fut))
    (local.get $status))

  ;; ======================= route handlers =======================

  ;; GET /checkout
  (func $do_checkout
    (local $prod_ptr i32) (local $prod_len i32) (local $d i32)
    (local $st i32) (local $u i32) (local $ulen i32)

    (call $getenv (global.get $S_e_product) (global.get $L_e_product))
    (local.set $prod_len)
    (local.set $prod_ptr)
    (if (i32.eqz (local.get $prod_ptr))
      (then (return (call $reply (i32.const 500) (global.get $S_err_env) (global.get $L_err_env) (i32.const 1)))))
    (if (i32.eqz (call $getenv_ptr_token))
      (then (return (call $reply (i32.const 500) (global.get $S_err_env) (global.get $L_err_env) (i32.const 1)))))

    ;; {"products":["<id>"]}
    (local.set $d (call $put (i32.const 0x2000) (global.get $S_j_ck_pre) (global.get $L_j_ck_pre)))
    (local.set $d (call $put (local.get $d) (local.get $prod_ptr) (local.get $prod_len)))
    (local.set $d (call $put (local.get $d) (global.get $S_j_ck_post) (global.get $L_j_ck_post)))

    (local.set $st
      (call $polar_post (global.get $S_p_checkout) (global.get $L_p_checkout)
        (i32.const 0x2000) (i32.sub (local.get $d) (i32.const 0x2000))))
    (if (i32.or (i32.lt_u (local.get $st) (i32.const 200)) (i32.ge_u (local.get $st) (i32.const 300)))
      (then (return (call $reply (i32.const 502) (global.get $S_err_up) (global.get $L_err_up) (i32.const 1)))))

    (local.set $u (call $resp_find (global.get $S_n_url) (global.get $L_n_url)))
    (if (i32.eqz (local.get $u))
      (then (return (call $reply (i32.const 502) (global.get $S_err_up) (global.get $L_err_up) (i32.const 1)))))
    (local.set $ulen (call $str_len (local.get $u)))

    ;; {"url":"<url>"}
    (local.set $d (call $put (i32.const 0x2800) (global.get $S_o_url_pre) (global.get $L_o_url_pre)))
    (local.set $d (call $put (local.get $d) (local.get $u) (local.get $ulen)))
    (local.set $d (call $put (local.get $d) (global.get $S_j_end) (global.get $L_j_end)))
    (call $reply (i32.const 200) (i32.const 0x2800) (i32.sub (local.get $d) (i32.const 0x2800)) (i32.const 1)))

  ;; Returns the token pointer (0 if missing).
  (func $getenv_ptr_token (result i32)
    (local $p i32)
    (call $getenv (global.get $S_e_token) (global.get $L_e_token))
    (drop)
    (local.set $p)
    (local.get $p))

  ;; GET /validate and GET /use.  $use = 1 increments usage.
  (func $do_license (param $path i32) (param $path_len i32) (param $use i32)
    (local $key_ptr i32) (local $key_len i32) (local $org_ptr i32) (local $org_len i32)
    (local $d i32) (local $st i32) (local $p i32) (local $granted i32)
    (local $limit i32) (local $limit_ok i32) (local $usage i32) (local $usage_ok i32)
    (local $valid i32)

    (call $query_key (local.get $path) (local.get $path_len))
    (local.set $key_len)
    (local.set $key_ptr)
    (if (i32.or (i32.eqz (local.get $key_ptr)) (i32.eqz (local.get $key_len)))
      (then (return (call $reply (i32.const 400) (global.get $S_missingkey) (global.get $L_missingkey) (i32.const 0)))))
    (if (i32.eqz (call $json_safe (local.get $key_ptr) (local.get $key_len)))
      (then (return (call $reply (i32.const 400) (global.get $S_missingkey) (global.get $L_missingkey) (i32.const 0)))))

    (call $getenv (global.get $S_e_org) (global.get $L_e_org))
    (local.set $org_len)
    (local.set $org_ptr)
    (if (i32.eqz (local.get $org_ptr))
      (then (return (call $reply (i32.const 500) (global.get $S_err_env) (global.get $L_err_env) (i32.const 1)))))
    (if (i32.eqz (call $getenv_ptr_token))
      (then (return (call $reply (i32.const 500) (global.get $S_err_env) (global.get $L_err_env) (i32.const 1)))))

    ;; {"key":"<key>","organization_id":"<org>"}  (+ ,"increment_usage":1)
    (local.set $d (call $put (i32.const 0x2000) (global.get $S_j_key_pre) (global.get $L_j_key_pre)))
    (local.set $d (call $put (local.get $d) (local.get $key_ptr) (local.get $key_len)))
    (local.set $d (call $put (local.get $d) (global.get $S_j_org) (global.get $L_j_org)))
    (local.set $d (call $put (local.get $d) (local.get $org_ptr) (local.get $org_len)))
    (if (local.get $use)
      (then (local.set $d (call $put (local.get $d) (global.get $S_j_inc) (global.get $L_j_inc))))
      (else (local.set $d (call $put (local.get $d) (global.get $S_j_end) (global.get $L_j_end)))))

    (local.set $st
      (call $polar_post (global.get $S_p_validate) (global.get $L_p_validate)
        (i32.const 0x2000) (i32.sub (local.get $d) (i32.const 0x2000))))

    ;; Polar rejected the key (or failed): invalid.
    (if (i32.ne (local.get $st) (i32.const 200))
      (then
        (if (local.get $use)
          (then (return (call $reply (i32.const 400) (global.get $S_err_use) (global.get $L_err_use) (i32.const 1)))))
        (local.set $d (call $put (i32.const 0x2800) (global.get $S_o_valid_f) (global.get $L_o_valid_f)))
        (local.set $d (call $put (local.get $d) (global.get $S_null) (global.get $L_null)))
        (local.set $d (call $put (local.get $d) (global.get $S_o_usage) (global.get $L_o_usage)))
        (local.set $d (call $put (local.get $d) (global.get $S_null) (global.get $L_null)))
        (local.set $d (call $put (local.get $d) (global.get $S_o_close) (global.get $L_o_close)))
        (return (call $reply (i32.const 200) (i32.const 0x2800) (i32.sub (local.get $d) (i32.const 0x2800)) (i32.const 1)))))

    ;; status == "granted"
    (local.set $p (call $resp_find (global.get $S_n_status) (global.get $L_n_status)))
    (if (local.get $p)
      (then
        (local.set $granted
          (i32.and
            (call $memeq (local.get $p) (global.get $S_granted) (global.get $L_granted))
            (i32.eq (i32.load8_u (i32.add (local.get $p) (global.get $L_granted))) (i32.const 0x22))))))

    ;; limit_usage (number or null)
    (local.set $p (call $resp_find (global.get $S_n_limit) (global.get $L_n_limit)))
    (if (local.get $p)
      (then
        (call $parse_u32 (local.get $p))
        (local.set $limit_ok)
        (local.set $limit)))

    ;; usage
    (local.set $p (call $resp_find (global.get $S_n_usage) (global.get $L_n_usage)))
    (if (local.get $p)
      (then
        (call $parse_u32 (local.get $p))
        (local.set $usage_ok)
        (local.set $usage)))

    (local.set $valid
      (i32.and (local.get $granted)
        (i32.and (local.get $limit_ok)
          (i32.and (local.get $usage_ok)
            (i32.lt_u (local.get $usage) (local.get $limit))))))

    (if (local.get $use)
      (then
        (if (local.get $valid)
          (then (return (call $reply (i32.const 200) (global.get $S_o_use_t) (global.get $L_o_use_t) (i32.const 1))))
          (else (return (call $reply (i32.const 200) (global.get $S_o_use_f) (global.get $L_o_use_f) (i32.const 1)))))))

    ;; {"valid":<bool>,"limitUsage":<n|null>,"usage":<n|null>}
    (if (local.get $valid)
      (then (local.set $d (call $put (i32.const 0x2800) (global.get $S_o_valid_t) (global.get $L_o_valid_t))))
      (else (local.set $d (call $put (i32.const 0x2800) (global.get $S_o_valid_f) (global.get $L_o_valid_f)))))
    (if (local.get $limit_ok)
      (then (local.set $d (call $put_u32 (local.get $d) (local.get $limit))))
      (else (local.set $d (call $put (local.get $d) (global.get $S_null) (global.get $L_null)))))
    (local.set $d (call $put (local.get $d) (global.get $S_o_usage) (global.get $L_o_usage)))
    (if (local.get $usage_ok)
      (then (local.set $d (call $put_u32 (local.get $d) (local.get $usage))))
      (else (local.set $d (call $put (local.get $d) (global.get $S_null) (global.get $L_null)))))
    (local.set $d (call $put (local.get $d) (global.get $S_o_close) (global.get $L_o_close)))
    (call $reply (i32.const 200) (i32.const 0x2800) (i32.sub (local.get $d) (i32.const 0x2800)) (i32.const 1)))

  ;; ======================= entry point =======================

  ;; handle: func(request: incoming-request, response-out: response-outparam)
  (func (export "cm32p2|wasi:http/incoming-handler@0.2|handle")
    (param $req i32) (param $out i32)
    (local $path i32) (local $len i32) (local $method i32)
    (local $resp i32) (local $fields i32) (local $body i32) (local $stream i32)

    ;; method variant tag (u8): 0 = get, 6 = options
    (call $req_method (local.get $req) (i32.const 32))
    (local.set $method (i32.load8_u (i32.const 32)))

    ;; option<string> at 16: tag, pointer, length.
    (call $req_path (local.get $req) (i32.const 16))
    (if (i32.load8_u (i32.const 16))
      (then
        (local.set $path (i32.load (i32.const 20)))
        (local.set $len (i32.load (i32.const 24)))))

    (call $read_origin (local.get $req))
    (call $req_drop (local.get $req))

    ;; Sandbox when the Origin contains "localhost:1337".
    (if (global.get $origin_ptr)
      (then
        (global.set $sandbox
          (i32.ne (i32.const 0)
            (call $find (global.get $origin_ptr) (global.get $origin_len)
              (global.get $S_localhost) (global.get $L_localhost))))))

    ;; Load environment once.
    (call $get_environment (i32.const 0x108))
    (global.set $env_ptr (i32.load (i32.const 0x108)))
    (global.set $env_n (i32.load (i32.const 0x10c)))

    ;; ---- route ----
    (call $reply (i32.const 404) (global.get $S_notfound) (global.get $L_notfound) (i32.const 0))

    (if (i32.eq (local.get $method) (i32.const 6))
      (then (call $reply (i32.const 204) (i32.const 0) (i32.const 0) (i32.const 0)))
      (else
        (if (call $is_route (local.get $path) (local.get $len) (global.get $S_r_root) (global.get $L_r_root))
          (then (call $reply (i32.const 200) (global.get $S_root) (global.get $L_root) (i32.const 0))))
        (if (call $is_route (local.get $path) (local.get $len) (global.get $S_r_checkout) (global.get $L_r_checkout))
          (then (call $do_checkout)))
        (if (call $is_route (local.get $path) (local.get $len) (global.get $S_r_validate) (global.get $L_r_validate))
          (then (call $do_license (local.get $path) (local.get $len) (i32.const 0))))
        (if (call $is_route (local.get $path) (local.get $len) (global.get $S_r_use) (global.get $L_r_use))
          (then (call $do_license (local.get $path) (local.get $len) (i32.const 1))))))

    ;; ---- response headers ----
    (local.set $fields (call $fields_new))

    ;; CORS only for allowed origins (reflect the origin).
    (if (call $origin_allowed)
      (then
        (call $fields_append (local.get $fields)
          (global.get $S_h_acao) (global.get $L_h_acao)
          (global.get $origin_ptr) (global.get $origin_len) (i32.const 0x40))
        (call $fields_append (local.get $fields)
          (global.get $S_h_acam) (global.get $L_h_acam)
          (global.get $S_v_methods) (global.get $L_v_methods) (i32.const 0x40))
        (call $fields_append (local.get $fields)
          (global.get $S_h_acah) (global.get $L_h_acah)
          (global.get $S_h_ct) (global.get $L_h_ct) (i32.const 0x40))
        (call $fields_append (local.get $fields)
          (global.get $S_h_vary) (global.get $L_h_vary)
          (global.get $S_origin) (global.get $L_origin) (i32.const 0x40))))

    (if (global.get $r_json)
      (then
        (call $fields_append (local.get $fields)
          (global.get $S_h_ct) (global.get $L_h_ct)
          (global.get $S_ct_json) (global.get $L_ct_json) (i32.const 0x40)))
      (else
        (call $fields_append (local.get $fields)
          (global.get $S_h_ct) (global.get $L_h_ct)
          (global.get $S_ct_text) (global.get $L_ct_text) (i32.const 0x40))))

    (local.set $resp (call $resp_new (local.get $fields)))
    (drop (call $resp_set_status (local.get $resp) (global.get $r_status)))

    ;; result<outgoing-body>: tag at 0x40, handle at 0x44.
    (call $resp_body (local.get $resp) (i32.const 0x40))
    (local.set $body (i32.load (i32.const 0x44)))

    ;; ok(resp); trailing zeros pad the flattened error-code variant.
    (call $outparam_set
      (local.get $out)
      (i32.const 0)
      (local.get $resp)
      (i32.const 0) (i64.const 0)
      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))

    (call $body_write (local.get $body) (i32.const 0x40))
    (local.set $stream (i32.load (i32.const 0x44)))
    (call $stream_write
      (local.get $stream) (global.get $r_ptr) (global.get $r_len) (i32.const 0x40))
    (call $stream_drop (local.get $stream))

    (call $body_finish
      (local.get $body) (i32.const 0) (i32.const 0) (i32.const 0x40))))
