#!/bin/bash
set -Eeuo pipefail

##
# Configuration
##

NGINX_TRACK="stable" # stable is 1.30.3 (as of last update to this script)

OPENSSL_VER="4.0.1"
OPENSSL_SHA256="2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
STATIC_SSL_PATH="/opt/openssl-pq-static"

HEADERS_MORE_REF="0bf283ff92017acd616814b0e5153e0ccf93e2c9" # identical to v0.40

NGX_BROTLI_REF="a71f9312c2deb28875acc7bacfdd5695a111aa53" # 9 commits ahead of v1.0.0rc
BROTLI_CFLAGS="-O3 -fPIC"

WORKDIR="/root/build-nginx-pq"
LOG_FILE="/root/nginx_build.log"
CODENAME=$(lsb_release -cs)

# Ensure we use gcc for this (no zig/clang)
export CC=gcc

# Deb Packaging Identity
export DEBEMAIL="laura@wiese2.org"
export DEBFULLNAME="Laura"

# Timing variables
declare -A BUILD_TIMES

BUILD_START=0

##
# Logging
##

rm -f "$LOG_FILE"

exec > >(tee -a "${LOG_FILE}") 2>&1

function print_log() {
	echo -e "\033[1m[i] $1\033[0m"
}

function timer_start() {
	BUILD_START=$(date +%s)
}

function timer_stop() {
	local end=$(date +%s)
	local duration=$((end - BUILD_START))
	local minutes=$((duration / 60))
	local seconds=$((duration % 60))

	echo "${minutes}m ${seconds}s"
}

##
# Preparation
##

# Remove any previous hold so dpkg can upgrade cleanly
apt-mark unhold nginx 2>/dev/null || true

# Cleaning build directories
print_log "Cleaning build directories..."

rm -rf "${WORKDIR}" "${STATIC_SSL_PATH}"
mkdir -p "${WORKDIR}" "${STATIC_SSL_PATH}"

# Installing system dependencies
print_log "Installing dependencies..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
	curl ca-certificates gnupg2 lsb-release devscripts \
	dpkg-dev build-essential quilt perl python3 \
	libpcre2-dev libssl-dev zlib1g-dev libzstd-dev git cmake

##
# OpenSSL Build (Static)
##

cd "${WORKDIR}"

print_log "Downloading OpenSSL ${OPENSSL_VER}..."

curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "${OPENSSL_URL}" -o openssl.tar.gz || {
	print_log "ERROR: OpenSSL download failed. Aborting."
	exit 1
}

print_log "Verifying OpenSSL archive SHA-256..."

if ! printf '%s  %s\n' "${OPENSSL_SHA256}" "openssl.tar.gz" | sha256sum --check --status; then
	print_log "ERROR: OpenSSL SHA-256 verification failed. Aborting."
	print_log "Expected: ${OPENSSL_SHA256}"
	print_log "Actual:   $(sha256sum openssl.tar.gz | awk '{print $1}')"

	rm -f openssl.tar.gz

	exit 1
fi

print_log "OpenSSL archive SHA-256 verified"

tar -xzf openssl.tar.gz || {
	print_log "ERROR: OpenSSL archive extraction failed. Aborting."
	exit 1
}

mv openssl-* openssl-src

print_log "Building OpenSSL ${OPENSSL_VER} (Static)..."

timer_start

cd openssl-src

# Configure: Static libs, optimized
./Configure \
	--prefix="${STATIC_SSL_PATH}" \
	--libdir=lib \
	--openssldir="${STATIC_SSL_PATH}/ssl" \
	no-shared no-apps no-docs \
	enable-ec_nistp_64_gcc_128 \
	enable-tls1_3 enable-quic \
	enable-ktls \
	enable-zlib \
	enable-zstd \
	no-dtls \
	linux-x86_64

make -j"$(nproc)" || {
	print_log "ERROR: OpenSSL build failed. Aborting."

	exit 1
}

make test || {
	print_log "ERROR: OpenSSL tests failed. Aborting."

	exit 1
}

make install_sw || {
	print_log "ERROR: OpenSSL install failed. Aborting."

	exit 1
}

BUILD_TIMES[OpenSSL]=$(timer_stop)

print_log "OpenSSL installed to ${STATIC_SSL_PATH}"

# Verify OpenSSL build produced the required static libraries
for lib in libssl.a libcrypto.a; do
	if [ ! -f "${STATIC_SSL_PATH}/lib/${lib}" ]; then
		print_log "ERROR: OpenSSL build did not produce ${lib}. Aborting."

		exit 1
	fi
done

print_log "OpenSSL static libraries verified"

##
# Nginx Modules
##

# Headers More Module
print_log "Cloning headers-more-nginx-module at ${HEADERS_MORE_REF}..."

git clone https://github.com/openresty/headers-more-nginx-module.git "${WORKDIR}/headers-more-nginx-module"

git -C "${WORKDIR}/headers-more-nginx-module" checkout --detach "${HEADERS_MORE_REF}"

# Brotli Module
print_log "Cloning ngx_brotli at ${NGX_BROTLI_REF}..."

git clone --recurse-submodules https://github.com/google/ngx_brotli.git "${WORKDIR}/ngx_brotli"

git -C "${WORKDIR}/ngx_brotli" checkout --detach "${NGX_BROTLI_REF}"

git -C "${WORKDIR}/ngx_brotli" submodule update --init --recursive

# Build brotli library (static)
print_log "Building Brotli library..."

timer_start

cd "${WORKDIR}/ngx_brotli/deps/brotli"

mkdir -p out

cd out

cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="${BROTLI_CFLAGS}" .. || {
	print_log "ERROR: Brotli cmake failed. Aborting."

	exit 1
}

make -j"$(nproc)" || {
	print_log "ERROR: Brotli build failed. Aborting."

	exit 1
}

BUILD_TIMES[Brotli]=$(timer_stop)

# Verify Brotli build produced the required static libraries
for lib in libbrotlienc.a libbrotlicommon.a; do
	if [ ! -f "${WORKDIR}/ngx_brotli/deps/brotli/out/${lib}" ]; then
		print_log "ERROR: Brotli build did not produce ${lib}. Aborting."

		exit 1
	fi
done

print_log "Brotli static libraries verified"

##
# Nginx Source
##

cd "${WORKDIR}"

install -d /usr/share/keyrings

curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

# Stable repo is at /packages/debian, mainline is at /packages/mainline/debian
if [ "${NGINX_TRACK}" = "mainline" ]; then
	NGINX_REPO_URL="https://nginx.org/packages/mainline/debian"
else
	NGINX_REPO_URL="https://nginx.org/packages/debian"
fi

cat >/etc/apt/sources.list.d/nginx.list <<EOF
deb     [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${NGINX_REPO_URL} ${CODENAME} nginx
deb-src [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${NGINX_REPO_URL} ${CODENAME} nginx
EOF

apt-get update

# Fetch Source
apt-get build-dep -y nginx
apt-get source nginx

NGSRC_DIR="$(find . -maxdepth 1 -type d -name 'nginx-*' | sort | tail -n1)"

if [ -z "${NGSRC_DIR}" ]; then
	print_log "ERROR: Failed to fetch nginx source. Aborting."

	exit 1
fi

print_log "Using nginx source: ${NGSRC_DIR}"

cd "${NGSRC_DIR}"

##
# Patching
##

RULES="debian/rules"

print_log "Patching ${RULES}..."

# Show original for debugging
print_log "Original configure line:"
grep -n "\./configure" "${RULES}" | head -5

# Remove old OpenSSL flags (if present)
sed -i 's/--with-openssl=[^ ]*//g' "${RULES}"

# Inject Include Paths
sed -i "s|--with-cc-opt=\"|--with-cc-opt=\"-I${STATIC_SSL_PATH}/include -I${WORKDIR}/ngx_brotli/deps/brotli/c/include |g" "${RULES}"

# Inject Linker Flags
sed -i "s|--with-ld-opt=\"|--with-ld-opt=\"-L${STATIC_SSL_PATH}/lib -L${WORKDIR}/ngx_brotli/deps/brotli/out -Wl,-Bstatic -lssl -lcrypto -lbrotlienc -lbrotlicommon -Wl,-Bdynamic -Wl,-z,relro,-z,now -lz -lzstd -ldl -lpthread |g" "${RULES}"

# Ensure HTTP/3 is enabled
if ! grep -q "with-http_v3_module" "${RULES}"; then
	sed -i "s|\./configure |./configure --with-http_v3_module |g" "${RULES}"
fi

# Add modules - single line approach to avoid escaping issues
sed -i "s|\./configure |./configure --add-module=${WORKDIR}/headers-more-nginx-module --add-module=${WORKDIR}/ngx_brotli |g" "${RULES}"

# Show patched result for debugging
print_log "Patched configure line:"
grep -n "\./configure" "${RULES}" | head -5

# Verify critical patches were applied
if ! grep -q "openssl-pq-static" "${RULES}"; then
	print_log "ERROR: OpenSSL path not found in patched rules! Aborting."

	exit 1
fi

if ! grep -q "ngx_brotli" "${RULES}"; then
	print_log "ERROR: Brotli module not found in patched rules! Aborting."

	exit 1
fi

# Verify linker flags include required dynamic libraries
if ! grep -q "\-lz " "${RULES}" || ! grep -q "\-lzstd" "${RULES}"; then
	print_log "ERROR: Linker flags missing -lz and/or -lzstd (required by OpenSSL 4.0+). Aborting."
	print_log "Hint: Check that the sed injection includes '-lz -lzstd' in the -Bdynamic section."

	exit 1
fi

print_log "Patched rules verified"

##
# Build & Install
##

# Update Changelog
dch --local "+pq" -D "${CODENAME}" "Rebuild with Static OpenSSL ${OPENSSL_VER} + HTTP/3 + Brotli"

print_log "Building Nginx Package..."

timer_start

DEB_BUILD_OPTIONS=nocheck DEB_CFLAGS_MAINT_APPEND="-fstack-clash-protection" CC=gcc dpkg-buildpackage -b -uc -us -j"$(nproc)" -d || {
	PRINT_ELAPSED=$(timer_stop)

	print_log "ERROR: Nginx package build failed after ${PRINT_ELAPSED}. Check the log above."

	exit 1
}

BUILD_TIMES[Nginx]=$(timer_stop)

print_log "Installing..."

cd ..

if ! dpkg -i ./*.deb; then
	print_log "Local package install has unresolved dependencies; asking apt to resolve them..."

	apt-get -y -f install
fi

apt-mark hold nginx

# Verify the installed binary matches expectations
INSTALLED_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || true)

if [ -z "${INSTALLED_VER}" ]; then
	print_log "ERROR: nginx binary not found or not working after install. Aborting."

	exit 1
fi

INSTALLED_SSL=$(nginx -V 2>&1 | grep -oP 'built with OpenSSL \K[^ ]+' || true)

if [ "${INSTALLED_SSL}" != "${OPENSSL_VER}" ]; then
	print_log "ERROR: Built OpenSSL (${INSTALLED_SSL}) doesn't match requested version (${OPENSSL_VER})!"

	exit 1
fi

# Verify linkage is static
if ldd "$(command -v nginx)" 2>/dev/null | grep -qE 'libssl|libcrypto'; then
	print_log "ERROR: nginx is dynamically linked to OpenSSL!"

	exit 1
fi

# Report binary hardening status
if command -v hardening-check >/dev/null 2>&1; then
	print_log "nginx hardening status:"
	hardening-check "$(command -v nginx)" || true
else
	print_log "hardening-check unavailable; skipping hardening report"
fi

print_log "Installed nginx ${INSTALLED_VER} with OpenSSL ${INSTALLED_SSL}"

##
# Restart Nginx
##

print_log "Restarting nginx..."

if nginx -t 2>/dev/null; then
	systemctl restart nginx
	print_log "Nginx restarted successfully"
else
	print_log "WARNING: nginx config test failed, not restarting"
	nginx -t
fi

##
# Summary
##

echo
echo -e "\033[1m========================================\033[0m"
echo -e "\033[1m           BUILD SUMMARY\033[0m"
echo -e "\033[1m========================================\033[0m"
echo
echo -e "  OpenSSL:  ${BUILD_TIMES[OpenSSL]}"
echo -e "  Brotli:   ${BUILD_TIMES[Brotli]}"
echo -e "  Nginx:    ${BUILD_TIMES[Nginx]}"
echo
echo -e "\033[1m========================================\033[0m"
echo

nginx -V 2>&1

# Verify the built binary actually uses our OpenSSL
BUILT_SSL=$(nginx -V 2>&1 | grep -oP 'built with OpenSSL \K[^ ]+')

if [ "${BUILT_SSL}" != "${OPENSSL_VER}" ]; then
	print_log "ERROR: Built OpenSSL (${BUILT_SSL}) doesn't match requested version (${OPENSSL_VER})!"

	exit 1
fi

print_log "All is good :)"
