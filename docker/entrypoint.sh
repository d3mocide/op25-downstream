#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Defaults — override any of these with docker run -e VAR=value
# ---------------------------------------------------------------------------
: "${OP25_CONFIG:=cfg.json}"
: "${OP25_VERBOSITY:=1}"

: "${ICECAST_SOURCE_PASSWORD:=op25source}"
: "${ICECAST_RELAY_PASSWORD:=op25relay}"
: "${ICECAST_ADMIN_PASSWORD:=op25admin}"
: "${ICECAST_HOSTNAME:=localhost}"
: "${ICECAST_PORT:=8000}"
: "${ICECAST_HOST:=localhost}"
: "${ICECAST_MOUNT:=op25}"

: "${AUDIO_PORT:=23456}"
: "${AUDIO_GAIN:=1.35}"

# ---------------------------------------------------------------------------
# Validate that the config file exists in the mounted /config volume
# ---------------------------------------------------------------------------
if [ ! -f "/config/${OP25_CONFIG}" ]; then
    echo ""
    echo "ERROR: Config file not found at /config/${OP25_CONFIG}"
    echo ""
    echo "You must mount a directory containing your cfg.json (and any TSV files)"
    echo "to /config inside the container:"
    echo ""
    echo "  docker run -v /path/to/your/config:/config ... op25"
    echo ""
    echo "Set OP25_CONFIG if your config file has a different name:"
    echo "  docker run -e OP25_CONFIG=my_system.json -v ... op25"
    echo ""
    exit 1
fi

echo "OP25 starting with config: /config/${OP25_CONFIG}"

# ---------------------------------------------------------------------------
# Generate icecast.xml from template using envsubst
# ---------------------------------------------------------------------------
export ICECAST_SOURCE_PASSWORD ICECAST_RELAY_PASSWORD ICECAST_ADMIN_PASSWORD
export ICECAST_HOSTNAME ICECAST_PORT

envsubst < /etc/icecast2/icecast.xml.tmpl > /etc/icecast2/icecast.xml

# ---------------------------------------------------------------------------
# Build the audio command string for liquidsoap's OP25_AUDIO_CMD env var.
# liquidsoap will call this as a subprocess and read raw PCM from its stdout.
# ---------------------------------------------------------------------------
export OP25_AUDIO_CMD="/app/audio.py -u ${AUDIO_PORT} -x ${AUDIO_GAIN} -s"

# Export everything supervisord's %(ENV_*)s substitutions need
export OP25_CONFIG OP25_VERBOSITY
export ICECAST_HOST ICECAST_PORT ICECAST_MOUNT ICECAST_SOURCE_PASSWORD

echo "Icecast mount:  http://${ICECAST_HOSTNAME}:${ICECAST_PORT}/${ICECAST_MOUNT}"
echo "OP25 web UI:    http://0.0.0.0:8080"
echo ""

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
