FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    MUSICLINK_DATA=/config \
    SOURCE_DIR=/music \
    TARGET_DIR=/output

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        curl \
        nginx \
        openssl \
        nano \
        coreutils \
        procps \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

ARG TTYD_VERSION=1.7.7
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
        amd64)  TTYD_ARCH="x86_64"  ;; \
        arm64)  TTYD_ARCH="aarch64" ;; \
        armhf)  TTYD_ARCH="armv7l"  ;; \
        *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version

RUN mkdir -p /opt/musiclink
COPY musiclink.sh /opt/musiclink/musiclink.sh
RUN chmod +x /opt/musiclink/musiclink.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 7681

ENTRYPOINT ["/entrypoint.sh"]
