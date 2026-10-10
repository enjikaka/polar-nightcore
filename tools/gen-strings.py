import sys
S = [
 ("root","Welcome to the Nightcore.app Polar service on Wasmtime."),
 ("notfound","not found"),
 ("missingkey","Missing license key"),
 ("h_ct","content-type"),
 ("ct_text","text/plain; charset=utf-8"),
 ("ct_json","application/json; charset=utf-8"),
 ("h_acao","access-control-allow-origin"),
 ("h_acam","access-control-allow-methods"),
 ("h_acah","access-control-allow-headers"),
 ("h_vary","vary"),
 ("v_methods","GET, OPTIONS"),
 ("origin","origin"),
 ("h_auth","authorization"),
 ("bearer","Bearer "),
 ("h_ua","user-agent"),
 ("v_ua","nightcore-polar-wasm"),
 ("o1","https://nightcore.app"),
 ("o2","https://nightcore--polar.deno.dev"),
 ("o3","http://localhost:1337"),
 ("localhost","localhost:1337"),
 ("host_prod","api.polar.sh"),
 ("host_sbx","sandbox-api.polar.sh"),
 ("p_checkout","/v1/checkouts/"),
 ("p_validate","/v1/customer-portal/license-keys/validate"),
 ("r_root","/"),
 ("r_checkout","/checkout"),
 ("r_validate","/validate"),
 ("r_use","/use"),
 ("key_eq","key="),
 ("e_sandbox","SANDBOX_"),
 ("e_token","POLAR_ACCESS_TOKEN"),
 ("e_product","POLAR_PRODUCT_ID"),
 ("e_org","POLAR_ORGANIZATION_ID"),
 ("j_ck_pre",'{"products":["'),
 ("j_ck_post",'"]}'),
 ("j_key_pre",'{"key":"'),
 ("j_org",'","organization_id":"'),
 ("j_end",'"}'),
 ("j_inc",'","increment_usage":1}'),
 ("n_url",'"url":"'),
 ("n_status",'"status":"'),
 ("granted",'granted'),
 ("n_limit",'"limit_usage":'),
 ("n_usage",'"usage":'),
 ("null",'null'),
 ("o_url_pre",'{"url":"'),
 ("o_valid_t",'{"valid":true,"limitUsage":'),
 ("o_valid_f",'{"valid":false,"limitUsage":'),
 ("o_usage",',"usage":'),
 ("o_close",'}'),
 ("o_use_t",'{"valid":true}'),
 ("o_use_f",'{"valid":false}'),
 ("err_use",'{"message":"Licence key is not valid"}'),
 ("err_env",'{"message":"Missing environment variable"}'),
 ("err_up",'{"message":"Polar request failed"}'),
]
def esc(s):
    return s.replace('\\','\\\\').replace('"','\\"')
off=0x400
out=[";; ---- string table (generated offsets) ----"]
for name,s in S:
    n=len(s.encode())
    out.append(f'  (data (i32.const {off}) "{esc(s)}")')
    out.append(f'  (global $S_{name} i32 (i32.const {off}))')
    out.append(f'  (global $L_{name} i32 (i32.const {n}))')
    off+=(n+7)//8*8
assert off<0x2000, off
print("\n".join(out))
