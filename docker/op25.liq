#!/usr/bin/liquidsoap
# OP25 → Icecast streaming config for Docker deployment
# Liquidsoap >= 2.x
#
# Audio path:
#   audio.py (subprocess) reads PCM from UDP:AUDIO_PORT → writes to stdout
#   liquidsoap reads stdout → compresses/normalizes → encodes MP3 → streams to icecast2
#
# All tuneable parameters come from environment variables set by entrypoint.sh

settings.log.stdout.set(true)
settings.log.file.set(false)
settings.log.level.set(3)

# Must match OP25's 8 kHz PCM output
settings.frame.audio.size.set(8000)

# ---------------------------------------------------------------------------
# Audio source — reads OP25's UDP audio output via audio.py stdout
# AUDIO_PORT and AUDIO_GAIN are injected by entrypoint.sh
# ---------------------------------------------------------------------------
audio_cmd = environment.get(default="/app/audio.py -u 23456 -x 1.35 -s", "OP25_AUDIO_CMD")

input = input.external.rawaudio(
    buffer=0.25,
    channels=1,
    samplerate=8000,
    restart_on_error=true,
    audio_cmd
)

# ---------------------------------------------------------------------------
# Signal processing (matches the existing project example)
# ---------------------------------------------------------------------------
input = compress(
    input,
    attack=15.0, gain=2.0, knee=1.0,
    ratio=3.0, release=60.0, threshold=-24.0
)

input = normalize(
    input,
    gain_max=6.0, gain_min=-6.0,
    target=-16.0, threshold=-40.0
)

input_safe = mksafe(input)

# ---------------------------------------------------------------------------
# Icecast output
# ICECAST_PORT, ICECAST_MOUNT, ICECAST_SOURCE_PASSWORD are injected by entrypoint.sh
# ---------------------------------------------------------------------------
icecast_host = environment.get(default="localhost", "ICECAST_HOST")
icecast_port = int_of_string(environment.get(default="8000", "ICECAST_PORT"))
icecast_mount = environment.get(default="op25", "ICECAST_MOUNT")
icecast_pass  = environment.get(default="op25source", "ICECAST_SOURCE_PASSWORD")

output.icecast(
    %mp3(bitrate=16, samplerate=44100, stereo=false, internal_quality=0),
    description="OP25 P25 Scanner",
    genre="Public Safety",
    fallible=false,
    host=icecast_host,
    port=icecast_port,
    mount=icecast_mount,
    password=icecast_pass,
    input_safe
)
