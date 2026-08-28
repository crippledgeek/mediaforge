# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AMQP. MIT. SSL off to avoid OpenSSL+GPL nonfree contamination.
PKG_NAME="librabbitmq"
PKG_VERSION="${PKG_VERSION_LIBRABBITMQ:-0.15.0}"
PKG_GITHUB_REPO="alanxz/rabbitmq-c"
PKG_URL="https://github.com/alanxz/rabbitmq-c/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="rabbitmq-c-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librabbitmq"
PKG_CMAKE=true
# ENABLE_SSL_SUPPORT=OFF: AMQPS would pull in OpenSSL, which under --enable-gpl
# produces a nonfree (unredistributable) FFmpeg binary. Plain AMQP only.
# BUILD_TOOLS/BUILD_EXAMPLES require POPT and pull in extra deps; off for the lib.
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="-DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DINSTALL_STATIC_LIBS=ON -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DENABLE_SSL_SUPPORT=OFF -DRUN_SYSTEM_TESTS=OFF"
