ARG PYTHON_BASE_IMAGE=3.13-slim-trixie

# --- Stage 1: S6 Overlay Downloader ---
FROM ubuntu AS s6build
ARG S6_RELEASE
ENV S6_VERSION=${S6_RELEASE:-v3.1.6.2}
RUN apt-get update && apt-get install -y curl xz-utils
WORKDIR /tmp

RUN ARCH= && dpkgArch="$(dpkg --print-architecture)" \
  && case "${dpkgArch##*-}" in \
  amd64) ARCH='x86_64';; \
  arm64) ARCH='aarch64';; \
  armhf) ARCH='arm';; \
  *) echo "unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;; \
  esac \
  && set -ex \
  # Wir speichern die Dateien unter festen Namen, um Wildcard-Fehler zu vermeiden
  && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/$S6_VERSION/s6-overlay-noarch.tar.xz" -o s6-noarch.tar.xz \
  && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/$S6_VERSION/s6-overlay-$ARCH.tar.xz" -o s6-arch.tar.xz

# --- Stage 2: Main Build ---
FROM python:${PYTHON_BASE_IMAGE} AS build

ARG octoprint_ref
ENV octoprint_ref=${octoprint_ref:-master}

# System-Abhängigkeiten
RUN apt-get update && apt-get install -y --no-install-recommends \
  avrdude build-essential cmake curl imagemagick ffmpeg fontconfig \
  gcc g++ git haproxy libffi-dev libjpeg-dev libjpeg62-turbo \
  libprotobuf-dev libudev-dev libusb-1.0-0-dev libv4l-dev \
  openssh-client v4l-utils xz-utils zlib1g-dev x265 libpq-dev \
  && rm -rf /var/lib/apt/lists/*

# S6 Overlay installieren - Jetzt mit expliziten Namen und sauberer Syntax
COPY --from=s6build /tmp/s6-noarch.tar.xz /tmp/
COPY --from=s6build /tmp/s6-arch.tar.xz /tmp/
RUN tar -xf /tmp/s6-noarch.tar.xz -C / \
  && tar -xf /tmp/s6-arch.tar.xz -C / \
  && rm /tmp/s6-*.tar.xz

# Install octoprint
RUN	curl -fsSLO --compressed --retry 3 --retry-delay 10 \
  https://github.com/OctoPrint/OctoPrint/archive/${octoprint_ref}.tar.gz \
	&& mkdir -p /opt/octoprint \
  && tar xzf ${octoprint_ref}.tar.gz --strip-components 1 -C /opt/octoprint --no-same-owner \
  && rm ${octoprint_ref}.tar.gz

WORKDIR /opt/octoprint
RUN pip install --no-cache-dir . psycopg2
RUN mkdir -p /octoprint/octoprint /octoprint/plugins

# Install mjpg-streamer
RUN curl -fsSLO --compressed --retry 3 --retry-delay 10 \
  https://github.com/jacksonliam/mjpg-streamer/archive/master.tar.gz \
  && mkdir /mjpg && tar xzf master.tar.gz -C /mjpg && rm master.tar.gz
WORKDIR /mjpg/mjpg-streamer-master/mjpg-streamer-experimental
RUN make && make install

# Kopiere die vorbereiteten Services und Konfigurationen ins Image
COPY root /

# Berechtigungen für S6 v3 setzen
#RUN find /etc/s6-overlay/s6-rc.d/ -type f -exec sed -i 's/\r$//' {} + && \
#    find /etc/cont-init.d/ -type f -exec sed -i 's/\r$//' {} + && \
#    chmod +x /etc/cont-init.d/* && \
#    chmod -R +x /etc/s6-overlay/s6-rc.d/*/run

# Berechtigungen sicherstellen und Windows-Zeilenumbrüche entfernen
RUN find /etc/s6-overlay/s6-rc.d/ -type f -exec sed -i 's/\r$//' {} + && \
    chmod -R +x /etc/s6-overlay/s6-rc.d/*/run

# Umgebungsvariablen
ENV CAMERA_DEV=/dev/video0 \
    MJPG_STREAMER_INPUT="-n -r 640x480" \
    PIP_USER=true \
    PYTHONUSERBASE=/octoprint/plugins \
    PATH="/octoprint/plugins/bin:${PATH}" \
    OCTOPRINT_SERVER_COMMANDS_SERVERRESTARTCOMMAND="s6-svc -r /run/service/octoprint"

WORKDIR /octoprint
EXPOSE 80
VOLUME /octoprint

ENTRYPOINT ["/init"]
