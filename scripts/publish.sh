#!/usr/bin/env bash
set -euo pipefail

# Publish only after every matrix build (including ABI signature smoke test) passed.
artifact_dir="${1:?Usage: scripts/publish.sh <directory-of-debs>}"
if [[ -z "${APT_GPG_PRIVATE_KEY_B64:-}" || -z "${APT_SIGNING_FINGERPRINT:-}" ]]; then
  echo 'Configure repository secrets APT_GPG_PRIVATE_KEY_B64 and APT_SIGNING_FINGERPRINT.' >&2
  exit 1
fi
fingerprint="${APT_SIGNING_FINGERPRINT^^}"
if [[ ! "$fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
  echo 'APT_SIGNING_FINGERPRINT must contain 40 hexadecimal characters.' >&2
  exit 1
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo 'GITHUB_REPOSITORY is not set.' >&2
  exit 1
fi

shopt -s nullglob
packages=("$artifact_dir"/*.deb)
if (( ${#packages[@]} != 8 )); then
  echo "Expected eight verified packages (4 OS x 2 arches); got ${#packages[@]}." >&2
  exit 1
fi

export GNUPGHOME="$(mktemp -d)"
chmod 0700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s' "$APT_GPG_PRIVATE_KEY_B64" | base64 --decode | gpg --batch --import
if ! gpg --batch --list-secret-keys "$fingerprint" >/dev/null 2>&1; then
  echo "No GPG secret key matches $fingerprint" >&2
  exit 1
fi

# The gh-pages branch holds the repository's reprepro database so that
# publishing can update packages incrementally, not discard previous indexes.
site_dir="${APT_SITE_DIR:-$(mktemp -d)}"
mkdir -p "$site_dir"
if [[ -n "$(ls -A "$site_dir")" ]]; then
  echo "APT_SITE_DIR must be an empty directory: $site_dir" >&2
  exit 1
fi
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git fetch origin gh-pages:refs/remotes/origin/gh-pages
  git worktree add --detach "$site_dir" refs/remotes/origin/gh-pages
else
  git worktree add --detach "$site_dir" HEAD
  git -C "$site_dir" checkout --orphan apt-pages-initial
  git -C "$site_dir" rm -r -f -q .
fi

mkdir -p "$site_dir/conf"
{
  for codename in bookworm trixie noble resolute; do
    cat <<DIST
Origin: nginx-vts-packages
Label: nginx-vts-packages
Suite: $codename
Codename: $codename
Architectures: amd64 arm64
Components: main
Description: nginx-module-vts packages for stock Debian and Ubuntu NGINX
SignWith: $fingerprint

DIST
  done
} > "$site_dir/conf/distributions"

# Remove public keys retained by earlier versions of the gh-pages branch.
rm -f -- "$site_dir/public-key.gpg" "$site_dir/public-key.asc"
touch "$site_dir/.nojekyll"

for deb in "${packages[@]}"; do
  name="$(dpkg-deb -f "$deb" Package)"
  version="$(dpkg-deb -f "$deb" Version)"
  arch="$(dpkg-deb -f "$deb" Architecture)"
  [[ "$name" == nginx-http-vts-module ]] || { echo "Unexpected package $name" >&2; exit 1; }
  [[ "$arch" == amd64 || "$arch" == arm64 ]] || { echo "Unexpected architecture $arch" >&2; exit 1; }
  codename=''
  for distro in bookworm trixie noble resolute; do
    if [[ "$version" == *"~${distro}+nginx"* ]]; then
      codename="$distro"
      break
    fi
  done
  [[ -n "$codename" ]] || { echo "Cannot identify distro from: $version" >&2; exit 1; }

  # reprepro can hold one version per architecture in each suite. Repeated
  # scheduled builds with unchanged packages must not fail the deployment.
  if reprepro --basedir "$site_dir" list "$codename" "$name" \
      | awk -v a="$arch" -v v="$version" '$1 ~ ("\\|" a ":$") && $NF == v { found=1 } END {exit !found}'; then
    echo "Unchanged: $codename/$arch $version"
    continue
  fi
  echo "Publishing: $codename/$arch $version"
  reprepro --basedir "$site_dir" includedeb "$codename" "$deb"
done

reprepro --basedir "$site_dir" export
cat > "$site_dir/index.html" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>NGINX VTS packages</title></head>
<body>
  <h1>NGINX VTS packages</h1>
  <p>APT repository for Debian 12/13 and Ubuntu 24.04/26.04, amd64 and arm64.
     Built against the NGINX package shipped by each distribution.</p>
  <p><a href="https://github.com/muriyx/archive-keyring">APT signing key</a> ·
     <a href="https://github.com/${GITHUB_REPOSITORY}">Build source</a></p>
  <pre>deb [signed-by=/usr/share/keyrings/muriyx.gpg] https://muriyx.github.io/nginx-vts-packages/ CODENAME main</pre>
  <p>Replace CODENAME with bookworm, trixie, noble or resolute.</p>
</body></html>
HTML

if [[ ! -s "$site_dir/dists/bookworm/InRelease" || ! -s "$site_dir/dists/resolute/InRelease" ]]; then
  echo 'Signed APT indexes were not generated.' >&2
  exit 1
fi

git -C "$site_dir" config user.name 'github-actions[bot]'
git -C "$site_dir" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$site_dir" add -A
if git -C "$site_dir" diff --cached --quiet; then
  echo 'APT repository is unchanged.'
else
  git -C "$site_dir" commit -m "Update signed APT packages ($(date -u +%Y-%m-%d))"
  git -C "$site_dir" push origin HEAD:gh-pages
fi
