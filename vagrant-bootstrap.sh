# Skip if this VM was already provisioned (e.g., booted from the packaged
# uemu-prebuilt box). The marker is written at the end of this script.
PROVISION_MARKER="$HOME/.uemu-provisioned"
if [ -f "$PROVISION_MARKER" ]; then
    echo "uEmu already provisioned (marker: $PROVISION_MARKER). Skipping bootstrap."
    exit 0
fi

# Use all visible guest CPUs for compilation unless the caller caps it.
BUILD_JOBS="${UEMU_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)}"

# ---------------------------------------------------------------------------
# apt speedups
# ---------------------------------------------------------------------------
# 1) Swap the default (often slow / throttled) archive.ubuntu.com for a faster
#    mirror. Override with UEMU_APT_MIRROR=https://your.mirror/ubuntu.
# 2) Parallelise downloads so apt fetches many packages at once.
# 3) Skip the heavy `apt-get dist-upgrade` unless the caller opts in, and dedupe
#    the redundant `apt-get update` calls.
APT_MIRROR="${UEMU_APT_MIRROR:-http://mirrors.edge.kernel.org/ubuntu}"
if [ -w /etc/apt/sources.list ] || sudo -n true 2>/dev/null; then
    sudo sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu|${APT_MIRROR}|g" \
        -e "s|http://security.ubuntu.com/ubuntu|${APT_MIRROR}|g" \
        /etc/apt/sources.list
fi

sudo tee /etc/apt/apt.conf.d/99parallel >/dev/null <<'APTCONF'
Acquire::Queue-Mode "access";
Acquire::http::Pipeline-Depth "10";
Acquire::http::No-Cache "false";
Acquire::Languages "none";
APTCONF

# Non-interactive apt front-end so dpkg prompts don't stall provisioning.
export DEBIAN_FRONTEND=noninteractive
APT_GET="sudo -E apt-get -y -o Dpkg::Use-Pty=0"

sudo dpkg --add-architecture i386
$APT_GET update

if [ "${UEMU_APT_DIST_UPGRADE:-0}" = "1" ]; then
    $APT_GET dist-upgrade
fi

# Initial build dependencies and packages are taken from:
#    https://github.com/S2E/s2e/blob/master/Dockerfile#L35
$APT_GET install \
    build-essential cmake wget texinfo flex bison                          \
    python-dev python3-dev python3-venv python3-distro mingw-w64 lsb-release \
    libdwarf-dev libelf-dev libelf-dev:i386                                \
    libboost-dev zlib1g-dev libjemalloc-dev nasm pkg-config                \
    libmemcached-dev libpq-dev libc6-dev-i386 binutils-dev                 \
    libboost-system-dev libboost-serialization-dev libboost-regex-dev      \
    libbsd-dev libpixman-1-dev libncurses5                                 \
    libglib2.0-dev libglib2.0-dev:i386 python3-docutils libpng-dev         \
    gcc-multilib g++-multilib gcc-9 g++-9                                  \
    libtinfo5

# install git repo;
# 20.04 does only provide it as snap package, we opt in for manual installation
mkdir -p ~/.bin
PATH="${HOME}/.bin:${PATH}"
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+rx ~/.bin/repo

# setup env and directories
mkdir -p uemu/build
export uEmuDIR=$PWD/uemu

cd $uEmuDIR
~/.bin/repo init -u https://github.com/MCUSec/manifest.git -b uEmu
# Parallel fetch + shallow history speeds up sync substantially. Override
# UEMU_REPO_SYNC_JOBS=1 or UEMU_REPO_DEPTH=0 if the build needs full history.
REPO_SYNC_JOBS="${UEMU_REPO_SYNC_JOBS:-$BUILD_JOBS}"
REPO_DEPTH_FLAG=""
if [ "${UEMU_REPO_DEPTH:-1}" = "1" ]; then
    REPO_DEPTH_FLAG="--current-branch --no-clone-bundle"
fi
~/.bin/repo sync -j"$REPO_SYNC_JOBS" $REPO_DEPTH_FLAG

# fix permissions
chmod +x $uEmuDIR/s2e/libs2e/configure

# get ptracearm.h
sudo wget -P /usr/include/x86_64-linux-gnu/asm \
    https://raw.githubusercontent.com/MCUSec/uEmu/main/ptracearm.h

# start build process
cd $uEmuDIR/build && make -j"$BUILD_JOBS" -f $uEmuDIR/Makefile
sudo make -f $uEmuDIR/Makefile install

cd $uEmuDIR/AFL
make -j"$BUILD_JOBS"
sudo make install

# Set up environment for new connections
echo "export uEmuDIR=$uEmuDIR" >> ~/.bashrc

# Installation done, get all repositories
cd $uEmuDIR
git clone https://github.com/MCUSec/uEmu-unit_tests.git
git clone https://github.com/MCUSec/uEmu-real_world_firmware.git

# Mark provisioning complete so re-provision (and packaged-box boots) skip this.
touch "$PROVISION_MARKER"
