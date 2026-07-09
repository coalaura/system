#!/bin/bash
set -Eeuo pipefail

##
# Configuration
##

# apt-get update && apt-cache showsrc nginx | awk '$1 == "Version:" { print $2; exit }'
NGINX_TRACK="stable"
NGINX_DEB_VERSION="1.30.3-1~bookworm"
NGINX_UPSTREAM_VERSION="1.30.3"
NGINX_SIGNING_KEY_FPRS=(
	"8540A6F18833A80E9C1653A42FD21310B49F6B46" # signing-key-2@nginx.com
	"573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" # signing-key@nginx.com
	"9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3" # signing-key-3@nginx.com
)

OPENSSL_VER="4.0.1"
OPENSSL_SHA256="2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09"

HEADERS_MORE_REF="0bf283ff92017acd616814b0e5153e0ccf93e2c9" # identical to v0.40

NGX_BROTLI_REF="a71f9312c2deb28875acc7bacfdd5695a111aa53" # 9 commits ahead of v1.0.0rc
BROTLI_CFLAGS="-O3 -fPIC"

STATIC_SSL_PATH="/opt/openssl-pq-static"
WORKDIR="/root/build-nginx-pq"
LOG_FILE="/root/nginx_build.log"
CODENAME=$(
	. /etc/os-release
	printf '%s' "${VERSION_CODENAME:-}"
)

# Check we are root
if [ "${EUID}" -ne 0 ]; then
	printf 'ERROR: This script must be run as root. Aborting.\n' >&2
	exit 1
fi

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
# Platform preflight
##

if [ "$(dpkg --print-architecture)" != "amd64" ]; then
	print_log "ERROR: This script supports amd64 only; detected $(dpkg --print-architecture). Aborting."

	exit 1
fi

if [ "${CODENAME}" != "bookworm" ]; then
	print_log "ERROR: This script is pinned to bookworm; detected ${CODENAME}. Aborting."

	exit 1
fi

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
	binutils diffutils git cmake \
	libpcre2-dev libssl-dev zlib1g-dev libzstd-dev

##
# OpenSSL Build (Static)
##

cd "${WORKDIR}"

print_log "Downloading OpenSSL ${OPENSSL_VER}..."

OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"

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

OPENSSL_ARCHIVE_TOPDIR="openssl-${OPENSSL_VER}"

if ! tar -tzf openssl.tar.gz | awk -F/ -v expected="${OPENSSL_ARCHIVE_TOPDIR}" '
	BEGIN {
		valid = 1
		entries = 0
	}

	{
		entries++

		if ($1 != expected) {
			valid = 0
			exit
		}
	}

	END {
		exit !(valid && entries > 0)
	}
'; then
	print_log "ERROR: OpenSSL archive has an unexpected directory layout. Aborting."

	exit 1
fi

mkdir -p openssl-src

if ! tar -xzf openssl.tar.gz --no-same-owner --no-same-permissions --strip-components=1 -C openssl-src; then
	print_log "ERROR: OpenSSL archive extraction failed. Aborting."

	exit 1
fi

if [ ! -f "openssl-src/Configure" ]; then
	print_log "ERROR: Extracted OpenSSL source is missing Configure. Aborting."

	exit 1
fi

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

# Verify OpenSSL build produced valid static libraries.
for lib in libssl.a libcrypto.a; do
	lib_path="${STATIC_SSL_PATH}/lib/${lib}"

	if [ ! -f "${lib_path}" ]; then
		print_log "ERROR: OpenSSL build did not produce ${lib}. Aborting."

		exit 1
	fi

	if ! ar t "${lib_path}" >/dev/null; then
		print_log "ERROR: ${lib_path} is not a valid static archive. Aborting."

		exit 1
	fi
done

print_log "OpenSSL static libraries verified"

##
# Nginx Modules
##

# Headers More Module
print_log "Cloning headers-more-nginx-module at ${HEADERS_MORE_REF}..."

git clone --no-tags https://github.com/openresty/headers-more-nginx-module.git "${WORKDIR}/headers-more-nginx-module"

git -C "${WORKDIR}/headers-more-nginx-module" fsck --full --no-dangling

git -C "${WORKDIR}/headers-more-nginx-module" checkout --detach "${HEADERS_MORE_REF}"

if [ "$(git -C "${WORKDIR}/headers-more-nginx-module" rev-parse HEAD)" != "${HEADERS_MORE_REF}" ]; then
	print_log "ERROR: headers-more checkout does not match pinned commit ${HEADERS_MORE_REF}. Aborting."

	exit 1
fi

if [ ! -f "${WORKDIR}/headers-more-nginx-module/config" ]; then
	print_log "ERROR: headers-more source is missing its nginx module config file. Aborting."

	exit 1
fi

print_log "headers-more pinned commit verified"

# Brotli Module
print_log "Cloning ngx_brotli at ${NGX_BROTLI_REF}..."

git clone --no-tags https://github.com/google/ngx_brotli.git "${WORKDIR}/ngx_brotli"

git -C "${WORKDIR}/ngx_brotli" fsck --full --no-dangling

git -C "${WORKDIR}/ngx_brotli" checkout --detach "${NGX_BROTLI_REF}"

if [ "$(git -C "${WORKDIR}/ngx_brotli" rev-parse HEAD)" != "${NGX_BROTLI_REF}" ]; then
	print_log "ERROR: ngx_brotli checkout does not match pinned commit ${NGX_BROTLI_REF}. Aborting."

	exit 1
fi

git -C "${WORKDIR}/ngx_brotli" -c protocol.file.allow=never submodule update --init --recursive

git -C "${WORKDIR}/ngx_brotli" submodule foreach --recursive 'git fsck --full --no-dangling'

if [ ! -f "${WORKDIR}/ngx_brotli/config" ] || [ ! -f "${WORKDIR}/ngx_brotli/deps/brotli/CMakeLists.txt" ]; then
	print_log "ERROR: ngx_brotli source or its Brotli submodule is incomplete. Aborting."

	exit 1
fi

print_log "ngx_brotli pinned commit and submodules verified"

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

# Verify Brotli build produced valid static libraries.
for lib in libbrotlienc.a libbrotlicommon.a; do
	lib_path="${WORKDIR}/ngx_brotli/deps/brotli/out/${lib}"

	if [ ! -f "${lib_path}" ]; then
		print_log "ERROR: Brotli build did not produce ${lib}. Aborting."

		exit 1
	fi

	if ! ar t "${lib_path}" >/dev/null; then
		print_log "ERROR: ${lib_path} is not a valid static archive. Aborting."

		exit 1
	fi
done

print_log "Brotli static libraries verified"

##
# Nginx Source
##

cd "${WORKDIR}"

install -d -m 0755 /usr/share/keyrings

NGINX_SIGNING_KEY="${WORKDIR}/nginx_signing.key"
NGINX_KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"
EXPECTED_NGINX_KEY_FPRS="${WORKDIR}/expected-nginx-key-fingerprints.txt"
DOWNLOADED_NGINX_KEY_FPRS="${WORKDIR}/downloaded-nginx-key-fingerprints.txt"

curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 https://nginx.org/keys/nginx_signing.key -o "${NGINX_SIGNING_KEY}" || {
	print_log "ERROR: nginx signing-key download failed. Aborting."

	exit 1
}

gpg --show-keys --with-colons "${NGINX_SIGNING_KEY}" | awk -F: '
	$1 == "pub" { want_fingerprint = 1; next }
	want_fingerprint && $1 == "fpr" {
		print $10
		want_fingerprint = 0
	}
' | sort -u >"${DOWNLOADED_NGINX_KEY_FPRS}"

printf '%s\n' "${NGINX_SIGNING_KEY_FPRS[@]}" | sort -u >"${EXPECTED_NGINX_KEY_FPRS}"

if ! diff -u "${EXPECTED_NGINX_KEY_FPRS}" "${DOWNLOADED_NGINX_KEY_FPRS}"; then
	print_log "ERROR: Downloaded nginx signing-key set does not exactly match the pinned key set. Aborting."

	print_log "Expected primary fingerprints:"
	cat "${EXPECTED_NGINX_KEY_FPRS}"

	print_log "Downloaded primary fingerprints:"
	cat "${DOWNLOADED_NGINX_KEY_FPRS}"

	rm -f "${NGINX_SIGNING_KEY}" "${EXPECTED_NGINX_KEY_FPRS}" "${DOWNLOADED_NGINX_KEY_FPRS}"

	exit 1
fi

gpg --dearmor --yes -o "${NGINX_KEYRING}" "${NGINX_SIGNING_KEY}"

rm -f "${NGINX_SIGNING_KEY}" "${EXPECTED_NGINX_KEY_FPRS}" "${DOWNLOADED_NGINX_KEY_FPRS}"

print_log "nginx repository signing-key set verified"

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

apt-get build-dep -y "nginx=${NGINX_DEB_VERSION}"
apt-get source "nginx=${NGINX_DEB_VERSION}"

NGINXSRC_DIR="./nginx-${NGINX_UPSTREAM_VERSION}"

if [ ! -d "${NGINXSRC_DIR}" ]; then
	print_log "ERROR: Expected nginx source directory ${NGINXSRC_DIR} was not created. Aborting."

	exit 1
fi

cd "${NGINXSRC_DIR}"

FETCHED_NGINX_DEB_VERSION=$(dpkg-parsechangelog -S Version)

if [ "${FETCHED_NGINX_DEB_VERSION}" != "${NGINX_DEB_VERSION}" ]; then
	print_log "ERROR: Downloaded nginx source version does not match the pinned version. Aborting."
	print_log "Expected: ${NGINX_DEB_VERSION}"
	print_log "Actual:   ${FETCHED_NGINX_DEB_VERSION}"

	exit 1
fi

if [ ! -f "src/core/nginx.h" ]; then
	print_log "ERROR: nginx source is missing src/core/nginx.h. Aborting."

	exit 1
fi

NGINX_SOURCE_VERSION=$(
	awk '
		$1 == "#define" && $2 == "NGINX_VERSION" {
			version = $3
			gsub(/^"/, "", version)
			gsub(/"$/, "", version)
			print version
			exit
		}
	' src/core/nginx.h
)

if [ "${NGINX_SOURCE_VERSION}" != "${NGINX_UPSTREAM_VERSION}" ]; then
	print_log "ERROR: Downloaded nginx source does not match upstream version ${NGINX_UPSTREAM_VERSION}. Aborting."
	print_log "Actual source version: ${NGINX_SOURCE_VERSION:-<not found>}"

	exit 1
fi

print_log "Using verified nginx source ${FETCHED_NGINX_DEB_VERSION}"

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

EXPECTED_BUILT_NGINX_DEB_VERSION=$(dpkg-parsechangelog -S Version)

if [[ "${EXPECTED_BUILT_NGINX_DEB_VERSION}" != "${NGINX_DEB_VERSION}"+pq* ]]; then
	print_log "ERROR: Generated nginx package version is unexpected: ${EXPECTED_BUILT_NGINX_DEB_VERSION}. Aborting."

	exit 1
fi

print_log "Expected locally built nginx package version: ${EXPECTED_BUILT_NGINX_DEB_VERSION}"

print_log "Building Nginx Package..."

timer_start

DEB_CFLAGS_MAINT_APPEND="-fstack-clash-protection" CC=gcc dpkg-buildpackage -b -uc -us -j"$(nproc)" -d || {
	PRINT_ELAPSED=$(timer_stop)

	print_log "ERROR: Nginx package build failed after ${PRINT_ELAPSED}. Check the log above."

	exit 1
}

BUILD_TIMES[Nginx]=$(timer_stop)

print_log "Installing..."

cd ..

mapfile -t NGINX_DEBS < <(
	find . -maxdepth 1 -type f -name '*.deb' -print0 |

	while IFS= read -r -d '' deb; do
		if [ "$(dpkg-deb -f "${deb}" Package)" = "nginx" ] && [ "$(dpkg-deb -f "${deb}" Version)" = "${EXPECTED_BUILT_NGINX_DEB_VERSION}" ]; then
			printf '%s\n' "${deb}"
		fi
	done
)

if [ "${#NGINX_DEBS[@]}" -ne 1 ]; then
	print_log "ERROR: Expected exactly one locally built nginx .deb at version ${EXPECTED_BUILT_NGINX_DEB_VERSION}; found ${#NGINX_DEBS[@]}. Aborting."

	exit 1
fi

print_log "Verified local package: ${NGINX_DEBS[0]}"
sha256sum "${NGINX_DEBS[0]}"

# Preserve locally modified Debian conffiles, including nginx.conf and mime.types.
# A new conffile is installed only when it does not already exist.
if ! dpkg --force-confold -i ./*.deb; then
	print_log "Local package install has unresolved dependencies; asking apt to resolve them..."

	apt-get -y -o Dpkg::Options::="--force-confold" -f install
fi

apt-mark hold nginx

INSTALLED_NGINX_DEB_VERSION=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || true)

if [ "${INSTALLED_NGINX_DEB_VERSION}" != "${EXPECTED_BUILT_NGINX_DEB_VERSION}" ]; then
	print_log "ERROR: Installed nginx Debian package version does not match the locally built package. Aborting."
	print_log "Expected: ${EXPECTED_BUILT_NGINX_DEB_VERSION}"
	print_log "Actual:   ${INSTALLED_NGINX_DEB_VERSION:-<not installed>}"

	exit 1
fi

# Locally modified Debian conffiles are expected and deliberately preserved.
# Verify every other package file, while excluding only the package's declared conffiles.
NGINX_CONFFILES="${WORKDIR}/nginx-conffiles.txt"

dpkg-query -W -f='${Conffiles}\n' nginx | awk '$1 ~ /^\// { print $1 }' | sort -u >"${NGINX_CONFFILES}"

if ! DPKG_VERIFY_OUTPUT=$(dpkg -V nginx | awk '
	NR == FNR {
		conffile[$1] = 1
		next
	}

	{
		path = $NF

		if (!(path in conffile)) {
			print
		}
	}
' "${NGINX_CONFFILES}" -); then
	print_log "ERROR: dpkg verification command failed for the installed nginx package. Aborting."

	rm -f "${NGINX_CONFFILES}"

	exit 1
fi

rm -f "${NGINX_CONFFILES}"

if [ -n "${DPKG_VERIFY_OUTPUT}" ]; then
	print_log "ERROR: dpkg verification found modified or missing non-configuration files in the installed nginx package. Aborting."
	printf '%s\n' "${DPKG_VERIFY_OUTPUT}"

	exit 1
fi

if [ "$(dpkg-query -S "$(command -v nginx)" | cut -d: -f1)" != "nginx" ]; then
	print_log "ERROR: nginx executable is not owned by the installed nginx package. Aborting."

	exit 1
fi

print_log "Installed nginx package version and files verified"

# Verify the installed binary matches expectations
INSTALLED_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || true)

if [ -z "${INSTALLED_VER}" ]; then
	print_log "ERROR: nginx binary not found or not working after install. Aborting."

	exit 1
fi

if [ "${INSTALLED_VER}" != "${NGINX_UPSTREAM_VERSION}" ]; then
	print_log "ERROR: Installed nginx version does not match the requested upstream version. Aborting."
	print_log "Expected: ${NGINX_UPSTREAM_VERSION}"
	print_log "Actual:   ${INSTALLED_VER}"

	exit 1
fi

INSTALLED_SSL=$(nginx -V 2>&1 | grep -oP 'built with OpenSSL \K[^ ]+' || true)

if [ "${INSTALLED_SSL}" != "${OPENSSL_VER}" ]; then
	print_log "ERROR: Built OpenSSL (${INSTALLED_SSL}) doesn't match requested version (${OPENSSL_VER})!"

	exit 1
fi

# Verify linkage is static
NGINX_BINARY="$(command -v nginx)"
NGINX_BUILD_INFO="$(nginx -V 2>&1)"

# Check both the resolved runtime dependency tree and nginx's direct ELF
# NEEDED entries. Neither may reference a dynamic OpenSSL library.
if ldd "${NGINX_BINARY}" 2>/dev/null | grep -qE '(^|[[:space:]])lib(ssl|crypto)\.so'; then
	print_log "ERROR: nginx resolves a dynamic OpenSSL library at runtime. Aborting."

	exit 1
fi

if readelf -d "${NGINX_BINARY}" | grep -qE '\[(libssl|libcrypto)\.so'; then
	print_log "ERROR: nginx ELF NEEDED entries contain dynamic OpenSSL libraries. Aborting."

	exit 1
fi

# Confirm the expected source and statically added modules were actually used.
for required_option in "--with-http_v3_module" "--add-module=${WORKDIR}/headers-more-nginx-module" "--add-module=${WORKDIR}/ngx_brotli"; do
	if ! grep -Fq -- "${required_option}" <<<"${NGINX_BUILD_INFO}"; then
		print_log "ERROR: nginx was not built with required option: ${required_option}. Aborting."

		exit 1
	fi
done

print_log "nginx OpenSSL linkage and required build options verified"

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

if ! nginx -t; then
	print_log "ERROR: nginx configuration test failed. Aborting without restart."

	exit 1
fi

if ! systemctl restart nginx; then
	print_log "ERROR: nginx restart failed. Aborting."

	exit 1
fi

if ! systemctl is-active --quiet nginx; then
	print_log "ERROR: nginx is not active after restart. Aborting."

	exit 1
fi

print_log "Nginx configuration, restart, and active service state verified"

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
