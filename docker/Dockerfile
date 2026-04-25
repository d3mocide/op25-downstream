# OP25 Docker Image
# Multi-stage build: compile C++ GNU Radio blocks, then assemble runtime image.
#
# Usage:
#   docker build -t op25 .
#   docker run --device /dev/bus/usb -v /path/to/config:/config -p 8000:8000 -p 8080:8080 op25

# ---------------------------------------------------------------------------
# Stage 1: Build the C++ GNU Radio blocks
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    g++ \
    make \
    pkg-config \
    gnuradio-dev \
    gr-osmosdr \
    libboost-all-dev \
    libspdlog-dev \
    librtlsdr-dev \
    python3-dev \
    python3-numpy \
    pybind11-dev \
    swig \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src/

RUN mkdir -p /src/build && \
    cd /src/build && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make -j"$(nproc)" && \
    make install

# ---------------------------------------------------------------------------
# Stage 2: Runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    # GNU Radio runtime
    gnuradio \
    gr-osmosdr \
    # SDR hardware
    librtlsdr0 \
    # Python
    python3 \
    python3-numpy \
    python3-waitress \
    python3-requests \
    # Audio streaming stack
    icecast2 \
    liquidsoap \
    # Process supervision
    supervisor \
    # Config templating
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled GNU Radio blocks from builder
COPY --from=builder /usr/local /usr/local
RUN ldconfig

# Install OP25 Python application files
COPY op25/gr-op25_repeater/apps /app
COPY op25/gr-op25_repeater/www  /app/../www
WORKDIR /app

# Install Docker-specific support files
COPY docker/supervisord.conf     /etc/supervisor/conf.d/op25.conf
COPY docker/icecast.xml.tmpl     /etc/icecast2/icecast.xml.tmpl
COPY docker/op25.liq             /app/op25-docker.liq
COPY docker/entrypoint.sh        /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    chmod +x /app/*.py /app/*.sh 2>/dev/null || true && \
    # Icecast2 log directory
    mkdir -p /var/log/icecast2 && chown nobody:nogroup /var/log/icecast2 && \
    # Supervisor log directory
    mkdir -p /var/log/supervisor

# Port 8000: Icecast2 streams + admin UI
# Port 8080: OP25 web dashboard
EXPOSE 8000 8080

# Mount your config directory here: cfg.json, tgid-tags.tsv, etc.
VOLUME ["/config"]

ENTRYPOINT ["/entrypoint.sh"]
