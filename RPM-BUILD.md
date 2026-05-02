# Build And Run RPM (Build Host)

These steps build a binary RPM that contains:

- `/usr/libexec/copy-fail-blocker/lsm_loader`
- `/usr/libexec/copy-fail-blocker/block_af_alg.o`
- `block-af-alg.service`

## 1) Install RPM build dependencies

```bash
sudo dnf install -y \
  rpm-build rpmdevtools redhat-rpm-config \
  clang gcc \
  libbpf-devel elfutils-libelf-devel zlib-devel \
  systemd-rpm-macros
```

## 2) Prepare rpmbuild tree

```bash
rpmdev-setuptree
```

## 3) Create source tarball

From the project root:

```bash
VERSION=0.1.0
NAME=copy-fail-blocker
TARBALL="$HOME/rpmbuild/SOURCES/${NAME}-${VERSION}.tar.gz"

git archive --format=tar.gz \
  --prefix=${NAME}-${VERSION}/ \
  -o "$TARBALL" HEAD
```

## 4) Copy spec and service into rpmbuild inputs

```bash
cp copy-fail-blocker.spec "$HOME/rpmbuild/SPECS/"
cp block-af-alg.service "$HOME/rpmbuild/SOURCES/"
```

## 5) Build binary RPM

```bash
rpmbuild -bb "$HOME/rpmbuild/SPECS/copy-fail-blocker.spec"
```

The resulting binary RPM will be under:

```bash
ls -1 "$HOME/rpmbuild/RPMS"/*/copy-fail-blocker-*.rpm
```

## 6) Install and start on the build host

```bash
sudo dnf install -y "$HOME"/rpmbuild/RPMS/*/copy-fail-blocker-*.rpm

sudo systemctl daemon-reload
sudo systemctl enable --now block-af-alg.service
sudo systemctl status block-af-alg.service
```

## 7) Verify blocker behavior

```bash
python3 - << 'EOF'
import socket
try:
    socket.socket(38, socket.SOCK_SEQPACKET)
    print("Unexpected: AF_ALG socket creation succeeded")
except PermissionError as e:
    print(f"Success: blocked with {e}")
except OSError as e:
    print(f"Blocked/failed as expected: {e}")
EOF
```

## 8) Logs and troubleshooting

```bash
sudo journalctl -u block-af-alg.service -f
```
