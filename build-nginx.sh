#!/bin/bash
set -Eeuo pipefail

##
# Configuration
##

OPENSSL_VER="3.5.4"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"

STATIC_SSL_PATH="/opt/openssl-pq-static"
NGINX_TRACK="mainline"
WORKDIR="/root/build-nginx-pq"
CODENAME=$(lsb_release -cs)

# Deb Packaging Identity
export DEBEMAIL="laura@wiese2.org"
export DEBFULLNAME="Laura"

##
# Preparation
##

# Cleaning build directories
echo "[i] Cleaning build directories..."
rm -rf "${WORKDIR}" "${STATIC_SSL_PATH}"
mkdir -p "${WORKDIR}" "${STATIC_SSL_PATH}"

# Installing system dependencies
echo "[i] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
	curl ca-certificates gnupg2 lsb-release \
	devscripts dpkg-dev build-essential quilt perl python3 \
	libpcre3-dev zlib1g-dev git

##
# OpenSSL Build (Static)
##

echo "[i] Building OpenSSL ${OPENSSL_VER} (Static)..."
cd "${WORKDIR}"
curl -fsSL "${OPENSSL_URL}" -o openssl.tar.gz
tar -xzf openssl.tar.gz
mv openssl-* openssl-src
cd openssl-src

# Configure: Static libs, no tests, optimized
./Configure \
	--prefix="${STATIC_SSL_PATH}" \
	--libdir=lib \
	--openssldir="${STATIC_SSL_PATH}/ssl" \
	no-shared no-tests no-apps no-docs \
	enable-ec_nistp_64_gcc_128 \
	enable-tls1_3 enable-quic \
	linux-x86_64

make -j"$(nproc)"
make install_sw
echo "[+] OpenSSL installed to ${STATIC_SSL_PATH}"

##
# Nginx Modules
##

# Headers More Module
echo "[i] Cloning headers-more-nginx-module..."
git clone --depth 1 https://github.com/openresty/headers-more-nginx-module.git "${WORKDIR}/headers-more-nginx-module"

##
# Nginx Source
##

cd "${WORKDIR}"

# Ensure Official Repo exists
if [ ! -f /etc/apt/sources.list.d/nginx.list ]; then
	install -d /usr/share/keyrings
	curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

	cat >/etc/apt/sources.list.d/nginx.list <<EOF
deb     [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${NGINX_TRACK}/debian ${CODENAME} nginx
deb-src [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${NGINX_TRACK}/debian ${CODENAME} nginx
EOF

	apt-get update
fi

# Fetch Source
apt-get build-dep -y nginx
apt-get source nginx
NGSRC_DIR="$(find . -maxdepth 1 -type d -name 'nginx-*' | sort | tail -n1)"
cd "${NGSRC_DIR}"

##
# Patching
##

RULES="debian/rules"
echo "[i] Patching ${RULES}..."

# Remove old OpenSSL flags (if present)
sed -i 's/--with-openssl=[^ ]*//g' "${RULES}"

# Inject Include Paths
# Appends to --with-cc-opt
sed -i "s|--with-cc-opt=\"|--with-cc-opt=\"-I${STATIC_SSL_PATH}/include |g" "${RULES}"

# Inject Linker Flags
# Links SSL statically (-Wl,-Bstatic) and system libs dynamically
sed -i "s|--with-ld-opt=\"|--with-ld-opt=\"-L${STATIC_SSL_PATH}/lib -Wl,-Bstatic -lssl -lcrypto -Wl,-Bdynamic -ldl -lpthread |g" "${RULES}"

# 4. Ensure HTTP/3 is enabled
if ! grep -q "with-http_v3_module" "${RULES}"; then
	sed -i "s|./configure |./configure --with-http_v3_module |g" "${RULES}"
fi

# Add Headers More Module
sed -i "s|\./configure |\./configure --add-module=${WORKDIR}/headers-more-nginx-module |g" "${RULES}"

##
# Build & Install
##

# Update Changelog
dch --local "+pq" -D "${CODENAME}" "Rebuild with Static OpenSSL ${OPENSSL_VER} + HTTP/3"

echo "[i] Building Nginx Package..."
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -uc -us -j"$(nproc)"

echo "[i] Installing..."
cd ..
dpkg -i ./*.deb || apt-get -y -f install
apt-mark hold nginx

echo
echo "[i] Success. Verify OpenSSL version:"
nginx -V 2>&1 | grep 'built with OpenSSL'