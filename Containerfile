FROM archlinux:latest

RUN pacman -Syu --noconfirm base-devel git

RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder

RUN git clone https://github.com/arkanelinux/pkgbuild.git && \
    cd pkgbuild/arkane-keyring && \
    makepkg -sic --noconfirm && \
    cd ../arkdep && \
    makepkg -sic --noconfirm

USER root
WORKDIR /root

# Crea el node del dispositiu loop0 si no existeix
RUN [ -e /dev/loop0 ] || mknod /dev/loop0 b 7 0

# Inicialitza el directori de claus de pacman
RUN pacman-key --init

# Omple el keyring amb les claus oficials d'Arch Linux
RUN pacman-key --populate archlinux arkane

RUN mkdir arkdep-build.d

ENTRYPOINT ["arkdep-build"] 

