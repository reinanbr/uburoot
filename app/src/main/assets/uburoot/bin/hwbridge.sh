#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Android's audio, camera, sensors and location in Ubuntu, through the UbuRoot app's
# bridges (Hardware screen > Bridges). Installed by mount.sh (HARDWARE_ACCESS=1) as
# /usr/local/lib/uburoot/hwbridge with the links uburoot-audio, uburoot-camera,
# uburoot-sensors and uburoot-gps in /usr/local/bin; dispatches on $0.
# Root and the users granted the class (sudo uburoot-hw grant audio|camera|sensors|
# location USER) may use them.
set -u
BR=/usr/local/lib/uburoot/bridge-client
me=${0##*/}
die() {
    printf '%s: %s\n' "$me" "$*" >&2
    exit 1
}
num() { case "$1" in '' | *[!0-9]*) die "not a number: $1" ;; esac }
size() { case "$1" in [0-9]*x[0-9]*) ;; *) die "not a size (WIDTHxHEIGHT): $1" ;; esac }

audio_usage() {
    cat >&2 <<'EOF'
usage: uburoot-audio play [FILE]     raw PCM (s16le) from FILE or stdin to the phone's speaker
       uburoot-audio record          the phone's microphone to stdout (raw s16le)
       uburoot-audio pulse [--mic]   PulseAudio: an "android" sink (and source with --mic)
       uburoot-audio pulse off
Rate and channels: UBU_RATE (default 48000), UBU_CHANNELS (play 2, record 1).
  ffmpeg -i song.mp3 -f s16le -ar 48000 -ac 2 - | uburoot-audio play
  uburoot-audio record | ffmpeg -f s16le -ar 48000 -ac 1 -i - mic.wav
EOF
    exit 2
}

# PulseAudio through pipe modules: Pulse writes the sink's FIFO, a loop sends it to
# the app; with --mic the app's microphone fills the source's FIFO.
pulse() {
    command -v pactl >/dev/null || die "needs PulseAudio: sudo apt install pulseaudio pulseaudio-utils; then pulseaudio --start"
    pactl info >/dev/null 2>&1 || die "PulseAudio is not running: pulseaudio --start"
    d=${XDG_RUNTIME_DIR:-/tmp}/uburoot-pulse.$(id -u)
    if [ "${1:-}" = off ]; then
        # shellcheck disable=SC2046 # a list of pids
        [ -f "$d/pids" ] && kill $(cat "$d/pids") 2>/dev/null
        rm -f "$d/pids"
        pactl unload-module module-pipe-sink 2>/dev/null
        pactl unload-module module-pipe-source 2>/dev/null
        echo "PulseAudio bridge off"
        return 0
    fi
    if ! { mkdir -p "$d" && chmod 700 "$d"; }; then die "cannot create $d"; fi
    rate=${UBU_RATE:-48000}
    num "$rate"
    pactl load-module module-pipe-sink sink_name=android file="$d/sink" format=s16le rate="$rate" channels=2 \
        sink_properties=device.description=Android >/dev/null || die "cannot load module-pipe-sink"
    pactl set-default-sink android
    (while [ -p "$d/sink" ]; do "$BR" audio play "$rate" 2 <"$d/sink" 2>/dev/null || sleep 2; done) &
    echo $! >"$d/pids"
    if [ "${1:-}" = --mic ]; then
        pactl load-module module-pipe-source source_name=android_mic file="$d/source" format=s16le rate="$rate" \
            channels=1 source_properties=device.description=Android-mic >/dev/null || die "cannot load module-pipe-source"
        pactl set-default-source android_mic
        (while [ -p "$d/source" ]; do "$BR" audio record "$rate" 1 >"$d/source" 2>/dev/null || sleep 2; done) &
        echo $! >>"$d/pids"
    fi
    echo "PulseAudio: default sink 'android'${1:+ and source 'android_mic'} (uburoot-audio pulse off)"
}

case "$me" in
    uburoot-audio)
        rate=${UBU_RATE:-48000}
        num "$rate"
        case "${1:-}" in
            play)
                ch=${UBU_CHANNELS:-2}
                num "$ch"
                if [ $# -ge 2 ] && [ "$2" != - ]; then
                    exec "$BR" audio play "$rate" "$ch" <"$2"
                fi
                exec "$BR" audio play "$rate" "$ch"
                ;;
            record)
                ch=${UBU_CHANNELS:-1}
                num "$ch"
                exec "$BR" audio record "$rate" "$ch"
                ;;
            pulse)
                shift
                pulse "$@"
                ;;
            *) audio_usage ;;
        esac
        ;;
    uburoot-camera)
        case "${1:-}" in
            list) exec "$BR" camera list ;;
            snap)
                [ $# -ge 2 ] || die "usage: uburoot-camera snap FILE.jpg|- [CAMERA_ID] [WIDTHxHEIGHT]"
                id=${3:-0}
                sz=${4:-1280x720}
                num "$id"
                size "$sz"
                if [ "$2" = - ]; then exec "$BR" camera snap "$id" "$sz"; fi
                "$BR" camera snap "$id" "$sz" >"$2.part" && [ -s "$2.part" ] && mv -f "$2.part" "$2" && exit 0
                rm -f "$2.part"
                exit 1
                ;;
            mjpeg)
                id=${2:-0}
                sz=${3:-1280x720}
                num "$id"
                size "$sz"
                exec "$BR" camera mjpeg "$id" "$sz"
                ;;
            *)
                cat >&2 <<'EOF'
usage: uburoot-camera list                       cameras, facing, JPEG sizes
       uburoot-camera snap FILE.jpg|- [ID] [WxH]  one photo
       uburoot-camera mjpeg [ID] [WxH]           JPEG frames to stdout, until stopped
  uburoot-camera mjpeg 0 640x480 | ffmpeg -f mjpeg -i - -c:v libx264 video.mp4
  uburoot-camera mjpeg 1 | ffplay -f mjpeg -
EOF
                exit 2
                ;;
        esac
        ;;
    uburoot-sensors)
        case "${1:-}" in
            list) exec "$BR" sensors list ;;
            read)
                [ $# -ge 2 ] || die "usage: uburoot-sensors read SENSOR"
                exec "$BR" sensors read "$2"
                ;;
            stream)
                [ $# -ge 2 ] || die "usage: uburoot-sensors stream SENSOR [HZ]"
                hz=${3:-10}
                num "$hz"
                exec "$BR" sensors stream "$2" "$hz"
                ;;
            *)
                cat >&2 <<'EOF'
usage: uburoot-sensors list                  the phone's sensors (KEY, name, vendor)
       uburoot-sensors read KEY              one reading: "TIME_NS VALUE..."
       uburoot-sensors stream KEY [HZ]       readings until stopped (at most 200 Hz)
  KEY: accelerometer, gyroscope, magnetic_field, light, proximity, pressure... or a name.
EOF
                exit 2
                ;;
        esac
        ;;
    uburoot-gps)
        case "${1:-}" in
            nmea) exec "$BR" location nmea ;;
            fix) exec "$BR" location fix ;;
            *)
                cat >&2 <<'EOF'
usage: uburoot-gps nmea     the GNSS receiver's NMEA sentences, until stopped
       uburoot-gps fix      one position: "LAT LON ALTITUDE ACCURACY_M TIME_MS PROVIDER"
  gpsd: socat PTY,link=/tmp/gps0,raw EXEC:'uburoot-gps nmea' & gpsd -N /tmp/gps0
EOF
                exit 2
                ;;
        esac
        ;;
    *) die "run as uburoot-audio, uburoot-camera, uburoot-sensors or uburoot-gps" ;;
esac
