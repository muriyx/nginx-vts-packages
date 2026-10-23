#!/usr/bin/env bash
set -euo pipefail

deb_file="${1:?Usage: scripts/smoke-test.sh <package.deb>}"
package_name="$(dpkg-deb -f "$deb_file" Package)"
arch="$(dpkg-deb -f "$deb_file" Architecture)"
depends="$(dpkg-deb -f "$deb_file" Depends)"
provides="$(dpkg-query -W -f='${Provides}' nginx)"
nginx_abi="$(printf '%s' "$provides" | grep -oE 'nginx-abi-[^, ]+' | head -n 1)"

[[ "$package_name" == "libnginx-mod-http-vts" ]]
[[ "$arch" == "$(dpkg --print-architecture)" ]]
[[ -n "$nginx_abi" ]] || { echo 'nginx package has no virtual nginx-abi provide' >&2; exit 1; }
if [[ "$depends" != *"$nginx_abi"* ]]; then
  echo "Package is missing the expected NGINX ABI dependency: $nginx_abi" >&2
  echo "Actual dependencies: $depends" >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
dpkg-deb -x "$deb_file" "$scratch/unpacked"
module="$scratch/unpacked/usr/lib/nginx/modules/ngx_http_vhost_traffic_status_module.so"
[[ -s "$module" ]] || { echo "Missing .so in DEB: $module" >&2; exit 1; }
# dh_nginx must enable exactly the real VTS .so name; the package name alone
# would incorrectly infer ngx_http_vts_module.so.
loader="$scratch/unpacked/usr/share/nginx/modules-available/50-mod-http-vts.conf"
[[ -s "$loader" ]] || { echo "Missing NGINX module loader: $loader" >&2; exit 1; }
if ! grep -Fxq 'load_module modules/ngx_http_vhost_traffic_status_module.so;' "$loader"; then
  echo "NGINX module loader does not reference the correct .so: $loader" >&2
  exit 1
fi

cat > "$scratch/nginx.conf" <<CONF
load_module $module;
error_log stderr notice;
pid $scratch/nginx.pid;
events { worker_connections 64; }
http {
    vhost_traffic_status_zone;
    server {
        listen 127.0.0.1:18080;
        location = /status {
            vhost_traffic_status_display;
            vhost_traffic_status_display_format prometheus;
        }
    }
}
CONF
nginx -t -p "$scratch/" -c "$scratch/nginx.conf"
echo "Smoke test passed: $package_name ($arch), ABI $nginx_abi"
