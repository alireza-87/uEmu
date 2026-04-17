FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive
ENV uEmuDIR=/uemu

# ── Build dependencies (mirrors vagrant-bootstrap.sh) ─────────────────────────
# gcc-9 is not in 18.04 default repos — add the toolchain PPA first
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y software-properties-common && \
    add-apt-repository -y ppa:ubuntu-toolchain-r/test && \
    apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install -y \
        build-essential cmake wget texinfo flex bison \
        python python-dev python3-dev python3-venv python3-distutils python3-distro python3-pip \
        mingw-w64 lsb-release curl git \
        libdwarf-dev libelf-dev libelf-dev:i386 \
        libboost-dev zlib1g-dev libjemalloc-dev nasm pkg-config \
        libmemcached-dev libpq-dev libc6-dev-i386 binutils-dev \
        libboost-system-dev libboost-serialization-dev libboost-regex-dev \
        libbsd-dev libpixman-1-dev libncurses5 \
        libglib2.0-dev libglib2.0-dev:i386 python3-docutils libpng-dev \
        gcc-multilib g++-multilib gcc-9 g++-9 \
        libtinfo5 && \
    pip3 install jinja2 && \
    rm -rf /var/lib/apt/lists/*

# ── git-repo tool ──────────────────────────────────────────────────────────────
RUN curl https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo && \
    chmod a+rx /usr/local/bin/repo

# ── ptracearm.h fix (already in repo, copy instead of downloading) ────────────
COPY ptracearm.h /usr/include/x86_64-linux-gnu/asm/ptracearm.h

# ── Clone uEmu source ─────────────────────────────────────────────────────────
RUN mkdir -p $uEmuDIR/build
WORKDIR $uEmuDIR
RUN git config --global user.email "build@docker" && \
    git config --global user.name "Docker Build" && \
    repo init -u https://github.com/MCUSec/manifest.git -b uEmu && \
    repo sync

# ── Build uEmu ────────────────────────────────────────────────────────────────
# The S2E top-level Makefile builds components sequentially and manages its own
# sub-make parallelism internally — do NOT pass -j here or configure scripts
# for guest-tools32/64 will race and fail. Cores are used inside each component.
# Cleanup in the same RUN layer prevents containerd overlay ghost-file errors
# (e.g. libs2e-release/arm-s2e_sp-softmmu/libs2e.so lstat failure on export).
RUN chmod +x $uEmuDIR/s2e/libs2e/configure && \
    cd $uEmuDIR/build && \
    make -f $uEmuDIR/Makefile && \
    make -f $uEmuDIR/Makefile install && \
    find $uEmuDIR/build -mindepth 1 -maxdepth 1 ! -name "opt" -exec rm -rf {} +

# Register the installed LLVM runtime directory so libs2e can resolve
# libLTO.so.10/libRemarks.so.10 after the original build tree is cleaned.
RUN echo "/uemu/build/opt/lib" > /etc/ld.so.conf.d/uemu.conf && \
    ldconfig

# ── Build AFL (parallel) ──────────────────────────────────────────────────────
RUN cd $uEmuDIR/AFL && \
    make -j$(nproc) && \
    make install && \
    rm -rf $uEmuDIR/AFL

# ── Project helper scripts (copied from repo root) ────────────────────────────
RUN mkdir -p /uemu-tools
COPY uEmu-helper.py \
     launch-uEmu-template.sh \
     launch-AFL-template.sh \
     uEmu-config-template.lua \
     library.lua \
     /uemu-tools/

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
