#!/bin/bash
set -Eeuo pipefail

##
# Configuration
##

OPENSSL_VER="3.5.5"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"

STATIC_SSL_PATH="/opt/openssl-pq-static"
NGINX_TRACK="mainline"
WORKDIR="/root/build-nginx-pq"
LOG_FILE="/root/nginx_build.log"
CODENAME=$(lsb_release -cs)

# Deb Packaging Identity
export DEBEMAIL="laura@wiese2.org"
export DEBFULLNAME="Laura"

# Timing variables
declare -A BUILD_TIMES
BUILD_START=0

##
# Logging
##

rm -f $LOG_FILE

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
	libpcre3-dev zlib1g-dev git cmake

##
# OpenSSL Build (Static)
##

print_log "Building OpenSSL ${OPENSSL_VER} (Static)..."

timer_start

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

BUILD_TIMES[OpenSSL]=$(timer_stop)

print_log "OpenSSL installed to ${STATIC_SSL_PATH}"

##
# Nginx Modules
##

# Headers More Module
print_log "Cloning headers-more-nginx-module..."

git clone --depth 1 https://github.com/openresty/headers-more-nginx-module.git "${WORKDIR}/headers-more-nginx-module"

# Brotli Module
print_log "Cloning ngx_brotli module..."

git clone --recurse-submodules --depth 1 https://github.com/google/ngx_brotli.git "${WORKDIR}/ngx_brotli"

# Build brotli library (static)
print_log "Building Brotli library..."

timer_start

cd "${WORKDIR}/ngx_brotli/deps/brotli"

mkdir -p out

cd out

cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-Ofast -march=native -mtune=native -fPIC" ..

make -j"$(nproc)"

BUILD_TIMES[Brotli]=$(timer_stop)

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

print_log "Patching ${RULES}..."

# Show original for debugging
print_log "Original configure line:"
grep -n "\./configure" "${RULES}" | head -5

# Remove old OpenSSL flags (if present)
sed -i 's/--with-openssl=[^ ]*//g' "${RULES}"

# Inject Include Paths
sed -i "s|--with-cc-opt=\"|--with-cc-opt=\"-I${STATIC_SSL_PATH}/include -I${WORKDIR}/ngx_brotli/deps/brotli/c/include |g" "${RULES}"

# Inject Linker Flags
sed -i "s|--with-ld-opt=\"|--with-ld-opt=\"-L${STATIC_SSL_PATH}/lib -L${WORKDIR}/ngx_brotli/deps/brotli/out -Wl,-Bstatic -lssl -lcrypto -lbrotlienc -lbrotlicommon -Wl,-Bdynamic -ldl -lpthread |g" "${RULES}"

# Ensure HTTP/3 is enabled
if ! grep -q "with-http_v3_module" "${RULES}"; then
	sed -i "s|\./configure |./configure --with-http_v3_module |g" "${RULES}"
fi

# Add modules - single line approach to avoid escaping issues
sed -i "s|\./configure |./configure --add-module=${WORKDIR}/headers-more-nginx-module --add-module=${WORKDIR}/ngx_brotli |g" "${RULES}"

# Show patched result for debugging
print_log "Patched configure line:"
grep -n "\./configure" "${RULES}" | head -5

##
# Build & Install
##

# Update Changelog
dch --local "+pq" -D "${CODENAME}" "Rebuild with Static OpenSSL ${OPENSSL_VER} + HTTP/3 + Brotli"

print_log "Building Nginx Package..."

timer_start

DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -uc -us -j"$(nproc)"

BUILD_TIMES[Nginx]=$(timer_stop)

print_log "Installing..."

cd ..

dpkg -i ./*.deb || apt-get -y -f install

apt-mark hold nginx

##
# Restart Nginx
##

print_log "Restarting nginx..."

if nginx -t 2>/dev/null; then
	systemctl reload nginx || systemctl restart nginx
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