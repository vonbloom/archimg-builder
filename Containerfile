# --- Builder
FROM archlinux:latest AS builder

RUN pacman -Syu --noconfirm --needed base-devel git

RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder

RUN git clone --depth 1 https://github.com/arkanelinux/pkgbuild.git && \
    cd pkgbuild/arkane-keyring && \
    makepkg -sc --noconfirm && \
    cd ../arkdep && \
    makepkg -sc --noconfirm

# --- Runtime
FROM archlinux:latest

COPY --from=builder /home/builder/pkgbuild/arkane-keyring/*.pkg.tar.zst /tmp/
COPY --from=builder /home/builder/pkgbuild/arkdep/*.pkg.tar.zst /tmp/

RUN pacman -Syu --noconfirm && \
    pacman -U --noconfirm /tmp/*.pkg.tar.zst && \
    pacman-key --init && \
    pacman-key --populate archlinux arkane && \
    rm -rf /tmp/* && \
    pacman -Scc --noconfirm

WORKDIR /root
RUN mkdir arkdep-build.d

ENTRYPOINT ["arkdep-build"]
