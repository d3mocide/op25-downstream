# OP25 Architecture Reference

## Overview

OP25 is a GNU Radio-based P25 digital radio decoder for Software Defined Radio (SDR) hardware. It receives IQ samples from an SDR dongle, demodulates and decodes P25/DMR digital radio signals, and outputs decoded voice audio plus metadata. It supports P25 Phase 1, P25 Phase 2 (TDMA), Motorola SmartNet trunking, DMR, D-Star, YSF, and NBFM analog.

The system has two architectural layers: a C++ GNU Radio signal processing layer and a Python orchestration layer. These communicate via GNU Radio's internal message passing and shared UDP/WebSocket transports.

---

## Component Map

### C++ GNU Radio Blocks (`op25/gr-op25_repeater/lib/`)

These are compiled into shared libraries and loaded by GNU Radio at runtime. They do all DSP-heavy work.

| Block | File | Purpose |
|---|---|---|
| Frame Assembler | `p25_frame_assembler_impl.cc` | Core: assembles dibit stream into P25 frames; dispatches to Phase 1 or Phase 2 decoder |
| P25 Phase 1 | `p25p1_fdma.cc` | Decodes FDMA frames: error correction, talkgroup/RID extraction, voice codec |
| P25 Phase 2 | `p25p2_tdma.cc` | Decodes TDMA frames: slot demux, BPTC error correction, voice codec |
| Costas Loop | `costas_loop_cc_impl.cc` | Carrier phase/frequency tracking for CQPSK signals |
| Gardner Recovery | `gardner_cc_impl.cc` | Symbol clock recovery |
| FSK4 Slicer | `fsk4_slicer_fb_impl.cc` | Slices FSK4 symbols into dibits |
| Audio Output | `op25_audio.cc` | Routes decoded PCM to UDP, WebSocket, or file destinations |
| IMBE Vocoder | `imbe_vocoder/` | Decodes IMBE-encoded voice frames to PCM |
| AMBE Encoder | `ambe_encoder_sb_impl.cc` | AMBE voice codec support |
| Error Correction | `rs.cc`, `golay2087.cc`, `bptc19696.h` | Reed-Solomon, Golay, BPTC error correction |
| Crypto | `op25_crypt_adp.cc` | ADP/RC4, DES-OFB, AES-256-OFB decryption |

### Python Application Layer (`op25/gr-op25_repeater/apps/`)

Python code wires the GNU Radio blocks together and handles all system-level logic.

| File | Required | Purpose |
|---|---|---|
| `multi_rx.py` | **Yes** | Main entry point. Reads config, builds GNU Radio graph, manages all receivers and trunking. Replaces the legacy `rx.py` |
| `p25_demodulator_dev.py` | **Yes** | Builds the demodulation subgraph per channel: tuner → filter → Costas → Gardner → slicer |
| `p25_decoder.py` | **Yes** | Wraps the C++ frame assembler block; handles WAV output and Wireshark logging |
| `trunking.py` | Yes (trunked) | Monitors control channels, tracks voice frequency assignments, manages talkgroup blacklists/whitelists, handles adjacent sites |
| `tk_p25.py` | Yes (P25) | P25-specific trunking logic module |
| `tk_smartnet.py` | Yes (SmartNet) | Motorola SmartNet trunking logic module |
| `tk_trbo.py` | Yes (TRBO) | Motorola TRBO/Connect Plus trunking module |
| `sockaudio.py` | Optional | UDP audio receiver → ALSA/PulseAudio output. Not needed when liquidsoap handles audio |
| `audio.py` | Optional | Thin wrapper around `sockaudio.py` with `-s` (stdout) flag for liquidsoap input |
| `terminal.py` | Optional | HTTP web server (Waitress WSGI) + curses TUI. Serves the web dashboard on port 8080 |
| `http_server.py` | Optional | AJAX endpoints, JSON command dispatch, plot image serving |
| `icemeta.py` | Optional | Sends talkgroup metadata (not audio) to Icecast admin API via HTTP |
| `p25_nbfm.py` | Optional | NBFM analog demodulation block |
| `rms_agc.py` | Optional | RMS automatic gain control block |
| `gr_gnuplot.py` | Optional | Real-time gnuplot visualization |
| `rx.py` | No | Legacy single-channel entry point. Superseded by `multi_rx.py` |
| `tx/` | No | P25 transmission tools. Not needed for receive-only operation |

---

## Signal Processing Chain

One chain is instantiated per channel in the config:

```
osmosdr_source  (SDR hardware — RTL-SDR, Airspy, USRP, HackRF)
    │  Complex IQ samples @ configured sample rate (e.g. 1 Msps)
    ▼
Frequency Mixer  (tunes to channel center frequency)
    │  Baseband complex samples
    ▼
RRC / RC / GMSK Filter  (matched filter for modulation type)
    │
    ▼
Costas Loop  (tracks carrier phase and frequency — CQPSK only)
    │
    ▼
Gardner Clock Recovery  (symbol timing synchronization)
    │
    ▼
FSK4 / CQPSK Symbol Slicer  (complex samples → dibits)
    │  4800 dibits/sec
    ▼
RMS AGC  (automatic level control)
    │
    ▼
p25_frame_assembler  [C++ block]
    ├── Sync word detection
    ├── Reed-Solomon / Golay / BPTC error correction
    ├── p25p1_fdma  or  p25p2_tdma  decoder
    │       ├── Talkgroup / Radio ID extraction
    │       ├── Encryption detection
    │       └── IMBE/AMBE voice codec
    └── op25_audio  → UDP port (e.g. 23456)
```

---

## Audio Pipeline

Audio output has two paths depending on deployment:

### Local Playback (ALSA/PulseAudio)
```
p25_frame_assembler (C++ op25_audio block)
    │  PCM @ 8 kHz 16-bit signed, 320-byte UDP packets
    ▼  udp://127.0.0.1:23456
sockaudio.py  →  ALSA / PulseAudio device
```

### Icecast Streaming (headless / Docker)
```
p25_frame_assembler (C++ op25_audio block)
    │  PCM @ 8 kHz 16-bit signed, 320-byte UDP packets
    ▼  udp://127.0.0.1:23456
audio.py -s  (stdout mode, called by liquidsoap as subprocess)
    │  raw PCM on stdout
    ▼
liquidsoap  (compression → normalize → MP3 encode)
    │  MP3 stream via Shout protocol
    ▼
icecast2  (stream server, exposed on port 8000)

(parallel)
icemeta.py  →  HTTP POST to icecast2 /admin/metadata
               (updates "now playing" talkgroup tag per stream)
```

The audio and metadata paths are completely independent. Liquidsoap handles encoding and delivery; `icemeta.py` handles the talkgroup name overlay.

---

## Process Model

For a full deployment, four processes run concurrently:

| Process | What it is | Restart behavior |
|---|---|---|
| `icecast2` | Stream server | Must be up before liquidsoap connects |
| `multi_rx.py` | OP25 receiver (GNU Radio + Python) | Restarts on failure; starts sending audio to UDP immediately |
| `liquidsoap` | Audio encoder + Icecast source client | Restarts on failure; re-subscribes to icecast |
| (embedded) `icemeta.py` | Metadata thread inside multi_rx.py | Runs inside multi_rx.py process |

The HTTP web UI (port 8080) and the Icecast stream (port 8000) are independent — both can run simultaneously.

---

## Inter-Process Communication

| Transport | Used by | Data |
|---|---|---|
| UDP port 23456 | C++ block → audio.py / sockaudio.py | Raw PCM 8kHz 16-bit |
| UDP port 23457 | Second TDMA slot audio (optional) | Raw PCM 8kHz 16-bit |
| Shout protocol (TCP) | liquidsoap → icecast2 | Encoded MP3 stream |
| HTTP POST | icemeta.py → icecast2 `/admin/metadata` | Talkgroup tag text |
| HTTP GET/POST port 8080 | Browser → terminal.py | Status JSON, commands |
| WebSocket port 9000 | C++ block → web clients | Raw PCM stream (optional) |
| GNU Radio msg_queue | terminal.py ↔ multi_rx.py | Tuning commands, status |

---

## Configuration System

All runtime configuration goes in a single JSON file passed to `multi_rx.py -c your_config.json`.

### Top-level sections

```
cfg.json
├── channels[]      — One entry per logical receiver channel
├── devices[]       — SDR hardware definitions
├── trunking{}      — Trunked system configuration
├── metadata{}      — Icecast metadata (icemeta.py) settings
├── audio{}         — ALSA/PulseAudio output (omit when using liquidsoap)
└── terminal{}      — Web UI / curses TUI settings
```

### `channels[]` key fields

| Key | Description |
|---|---|
| `device` | References a device name from `devices[]` |
| `demod_type` | `"cqpsk"` (Phase 1/2) or `"fsk4"` (legacy) |
| `filter_type` | `"rc"`, `"rrc"`, or `"gmsk"` |
| `destination` | Where to send decoded PCM: `"udp://host:port"`, `"ws://host:port"` |
| `trunking_sysname` | Links channel to a trunking system defined in `trunking.chans[]` |
| `blacklist` / `whitelist` | Talkgroup ID filter files or inline lists |
| `crypt_behavior` | `0` = allow, `1` = silence, `2` = skip encrypted calls |
| `crypt_keys` | Path to JSON key file for decryption |

### `devices[]` key fields

| Key | Description |
|---|---|
| `args` | osmosdr device string: `"rtl"`, `"airspy"`, `"uhd"`, `"hackrf"` |
| `rate` | Sample rate in Hz (e.g. `1000000`) |
| `gains` | Gain string e.g. `"LNA:39"` |
| `ppm` | Frequency correction in PPM |
| `offset` | DC offset correction |

### `trunking.chans[]` key fields

| Key | Description |
|---|---|
| `sysname` | Unique system name (referenced by `channels[].trunking_sysname`) |
| `control_channel_list` | Comma-separated control channel frequencies in MHz |
| `tgid_tags_file` | Path to TSV file mapping talkgroup IDs to names |
| `rid_tags_file` | Path to TSV file mapping radio IDs to names |
| `whitelist` / `blacklist` | Talkgroup filters |
| `tdma_cc` | `true` if control channel is TDMA (Phase 2) |

---

## Talkgroup & Radio ID Files

Plain tab-separated files:

**`tgid-tags.tsv`**
```
# tgid    hex    tag              color
1001       0x3E9  "Fire Dispatch"  "#ff5c5c"
1002       0x3EA  "EMS Zone 1"     "#ffb84d"
```

**`rid-tags.tsv`**
```
# rid     hex    tag
100001    0x186A1 "Unit 101"
```

---

## Encryption Support

| Algorithm | algid | Notes |
|---|---|---|
| ADP / RC4 | `0xAA` | Most common on P25 Phase 1 |
| DES-OFB | `0x81` | Older systems |
| AES-256-OFB | `0x84` | Phase 2 systems |

Keys are provided in a JSON file referenced by `crypt_keys` in the channel config:
```json
[
  { "keyid": 1, "algid": "0xaa", "key": "0x0102030405060708090a0b0c0d0e0f" }
]
```

`crypt_behavior` controls what happens for calls without a matching key.

---

## Build System

The project uses CMake with two submodules:

```
CMakeLists.txt  (top-level)
├── op25/gr-op25/         — Legacy FSK4 demodulator block
└── op25/gr-op25_repeater/  — Main module
    ├── lib/              — C++ blocks → libgnuradio-op25_repeater.so
    ├── python/           — Python bindings (pybind11/SWIG)
    ├── grc/              — GNU Radio Companion block YAML
    └── apps/             — Python application code (not compiled)
```

Build output installed to `/usr/local/`:
- `lib/libgnuradio-op25*.so` — shared libraries
- `lib/python3.X/dist-packages/op25_repeater/` — Python module
- `share/gnuradio/grc/blocks/` — GRC block definitions

```bash
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
make -j$(nproc)
sudo make install
sudo ldconfig
```

---

## Runtime Dependencies

### Required system packages

| Package | Purpose |
|---|---|
| `gnuradio >= 3.10` | GNU Radio runtime |
| `gr-osmosdr` | SDR hardware abstraction (RTL, Airspy, USRP, HackRF) |
| `librtlsdr0` | RTL-SDR dongle driver |
| `python3` | Application runtime |
| `python3-numpy` | Signal processing arrays |

### Optional system packages

| Package | Purpose |
|---|---|
| `python3-waitress` | HTTP web UI server |
| `python3-requests` | Icecast metadata HTTP client |
| `libasound2` | ALSA audio output (local playback) |
| `libpulse0` | PulseAudio output (local playback) |
| `icecast2` | Stream server (headless/Docker deployment) |
| `liquidsoap >= 2.x` | Audio encoder + Icecast source client |

### Build-only packages

`cmake`, `g++`, `libboost-all-dev`, `gnuradio-dev`, `python3-dev`, `pybind11-dev`, `libspdlog-dev`

---

## Host Requirements for RTL-SDR

The kernel's DVB driver will claim RTL-SDR dongles before the SDR driver can. On the host:

1. Blacklist the DVB driver:
```bash
sudo cp blacklist-rtl.conf /etc/modprobe.d/
sudo modprobe -r dvb_usb_rtl28xxu
```

2. Install udev rules for non-root USB access:
```bash
sudo cp op25/gr-op25_repeater/apps/5-sdr_hw.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

These must be done on the **host system**, not inside a Docker container.

---

## What Can Be Dropped for a Minimal Deployment

The following are not needed for a headless receive + Icecast streaming setup:

| Component | Why droppable |
|---|---|
| `rx.py` | Superseded by `multi_rx.py` |
| `tx/` directory | Transmission only |
| `gr_gnuplot.py` | Visualization only |
| `op25_iqsrc.py`, `op25_wavsrc.py` | File-based IQ/WAV input (only needed for offline replay) |
| GRC `.grc` files | Design-time only, not needed at runtime |
| `docs/doxygen/` | Documentation generation |
| Curses terminal | Not usable on headless; HTTP UI is the alternative |
| `sockaudio.py` / `audio.py` | Replaced by liquidsoap's `input.external.rawaudio` call |
