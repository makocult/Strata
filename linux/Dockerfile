# Build and test without touching the host's Python or GPU services.
FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-dev python3-venv binutils dpkg-dev ca-certificates \
    libegl1 libgl1 libxkbcommon0 libxkbcommon-x11-0 libxcb-cursor0 \
    libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
    libxcb-render-util0 libxcb-shape0 libxcb-xfixes0 libxcb-sync1 \
    libxcb-xinerama0 libxcb-xkb1 libdbus-1-3 libfontconfig1 libglib2.0-0t64 \
    libgssapi-krb5-2 \
    libsecret-tools fonts-noto-cjk xvfb xauth dbus-x11 desktop-file-utils \
    libgtk-3-0 libatk1.0-0 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 \
    && apt-get clean
RUN python3 -m venv /opt/build-venv
ENV PATH=/opt/build-venv/bin:$PATH
COPY requirements-build.txt /opt/requirements-build.txt
RUN python -m pip install --no-cache-dir -r /opt/requirements-build.txt
WORKDIR /work
