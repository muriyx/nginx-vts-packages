#!/usr/bin/env bash
set -euo pipefail

# Run inside one of the supported stock Debian/Ubuntu container images.
# Expected: repository bind mounted at /workspace.
cd /workspace

codename="${1:?Usage: scripts/build.sh <bookworm|trixie|noble|resolute>}"
case "$codename" in
  bookworm|trixie|noble|resolute) ;;
  *) echo "Unsupported distribution: $codename" >&2; exit 1 ;;
esac

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${VERSION_CODENAME:-}" != "$codename" ]]; then
  echo "Container codename ${VERSION_CODENAME:-unknown} does not match $codename" >&2
  exit 1
fi
case "$codename:$ID" in
  bookworm:debian|trixie:debian|noble:ubuntu|resolute:ubuntu) ;;
  *) echo "Unsupported OS for $codename: $ID" >&2; exit 1 ;;
esac

# Minimal Ubuntu base images may have only 'main' enabled; nginx-dev is in universe.
if [[ "$ID" == ubuntu && -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  sed -i -E '/^Components:/ { /universe/! s/$/ universe/; }' /etc/apt/sources.list.d/ubuntu.sources
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl build-essential dpkg-dev debhelper \
  nginx nginx-dev

vts_version="${VTS_VERSION:-$(tr -d '[:space:]' < VTS_VERSION)}"
if [[ ! "$vts_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "Invalid VTS_VERSION: $vts_version" >&2
  exit 1
fi

nginx_version="$(dpkg-query -W -f='${Version}' nginx)"
nginx_dev_version="$(dpkg-query -W -f='${Version}' nginx-dev)"
if [[ "$nginx_version" != "$nginx_dev_version" ]]; then
  echo "nginx ($nginx_version) and nginx-dev ($nginx_dev_version) differ" >&2
  exit 1
fi
if [[ ! -f /usr/share/nginx/src/configure ]]; then
  echo "Missing distro build-system files in nginx-dev" >&2
  exit 1
fi

# Make distinct Debian package versions for each distro + installed distro NGINX
# package revision: reprepro must never confuse two incompatible binary builds.
nginx_revision="$(printf '%s' "$nginx_version" | sed -E 's/^[0-9]+://;s/-/./g')"
package_version="${vts_version}-1~${codename}+nginx${nginx_revision}"
arch="$(dpkg --print-architecture)"
work_dir="/workspace/.work/${codename}-${arch}"
source_dir="$work_dir/nginx-module-vts-$vts_version"
output_dir="/workspace/out/${codename}/${arch}"
mkdir -p "$work_dir" "$output_dir"
rm -rf "$source_dir"
mkdir -p "$source_dir"

archive="$work_dir/vts-v${vts_version}.tar.gz"
curl -fsSL --retry 3 --retry-delay 2 \
  "https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v${vts_version}.tar.gz" \
  -o "$archive"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"

# Preserve the BSD-2-Clause notice distributed with VTS; MIT applies only to
# scripts and packaging maintained by nginx-vts-packages.
test -s "$source_dir/LICENSE"
test -s "$source_dir/config"
cp -a packaging/debian "$source_dir/debian"
cat > "$source_dir/debian/changelog" <<CHANGELOG
libnginx-mod-http-vts ($package_version) $codename; urgency=medium

  * Build nginx-module-vts $vts_version against distro nginx $nginx_version.

 -- nginx-vts-packages contributors <noreply@github.com>  $(date -R)
CHANGELOG

(
  cd "$source_dir"
  dpkg-buildpackage -b -us -uc
)

shopt -s nullglob
built=("$work_dir"/libnginx-mod-http-vts_*_"$arch".deb)
if (( ${#built[@]} != 1 )); then
  echo "Expected exactly one libnginx-mod-http-vts .deb, got ${#built[@]}" >&2
  find "$work_dir" -maxdepth 1 -name '*.deb' -print >&2
  exit 1
fi
cp "${built[0]}" "$output_dir/"

# Fail the build if Debian's NGINX ABI metadata or module loading is wrong.
bash /workspace/scripts/smoke-test.sh "$output_dir/$(basename "${built[0]}")"
printf 'Built: %s\n' "$output_dir/$(basename "${built[0]}")"
