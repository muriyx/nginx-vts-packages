# nginx-vts-packages

Open-source Debian packages of [nginx-module-vts](https://github.com/vozlt/nginx-module-vts), compiled **against the
NGINX packages provided by each operating system**. No nginx.org packages, no custom NGINX binary, no third-party NGINX
repository.

## Platforms

| OS               | Codename | Architectures |
|------------------|----------|---------------|
| Debian 12        | bookworm | amd64, arm64  |
| Debian 13        | trixie   | amd64, arm64  |
| Ubuntu 24.04 LTS | noble    | amd64, arm64  |
| Ubuntu 26.04 LTS | resolute | amd64, arm64  |

The module package is named **`nginx-http-vts-module`**. 

## Installation

### Adding the repository to your system

1. Download and install the shared repository GPG key:

```bash
sudo curl -fsSL https://repo-keys.muriyx.com/archive-keyring.gpg \
    -o /usr/share/keyrings/muriyx.gpg
sudo chmod 0644 /usr/share/keyrings/muriyx.gpg
```

The public key is maintained separately and used to sign multiple projects.
For an existing installation, rerun this step to refresh the key.

2. Add the repository to your sources list:

```bash
. /etc/os-release
printf 'deb [signed-by=/usr/share/keyrings/muriyx.gpg] https://muriyx.github.io/nginx-vts-packages/ %s main\n' \
  "$VERSION_CODENAME" | sudo tee /etc/apt/sources.list.d/nginx-vts-packages.list
```

3. Update package index:

```bash
sudo apt update
```

### Installing packages

1. Install package:

```bash
sudo apt install nginx-http-vts-module
```

2. Restart nginx:

```bash
systemctl restart nginx
```

## Configuration

NGINX's Debian packaging is expected to enable the dynamic module under `/etc/nginx/modules-enabled/`. Check
`ls -l /etc/nginx/modules-enabled/*vts*` if the VTS directives are not recognized. If you previously inserted a manual
`load_module` directive, **remove the duplicate** before testing.

Minimal VTS configuration inside your NGINX `http { ... }` block:

```nginx
vhost_traffic_status_zone;

server {
    listen 127.0.0.1:8081;
    location = /status {
        allow 127.0.0.1;
        deny all;
        vhost_traffic_status_display;
        vhost_traffic_status_display_format prometheus;
    }
}
```

Treat VTS HTTP/control endpoints as internal infrastructure; never expose them publicly without additional access
controls.

### Local build

On a machine with Docker:

```bash
# Example: build Debian 13 amd64
sudo docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace" -w /workspace \
  debian:13 bash scripts/build.sh trixie
```

The verified `.deb` appears in `out/trixie/amd64/`.

## License

**This repository's scripts, build orchestration and packaging are MIT licensed**; see [LICENSE](LICENSE). The separate
upstream [nginx-module-vts](https://github.com/vozlt/nginx-module-vts) project is **BSD-2-Clause licensed** and remains
so.

This project is independently maintained and is not affiliated with NGINX, Debian, Ubuntu or the nginx-module-vts
maintainers.
