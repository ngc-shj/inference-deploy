# The GPU load sampler the ABBA keeps beside each arm, sourced by m4abba.sh.
#
#   gpusampler_start <file>   sample render, tiler and device load every 5 s
#   gpusampler_stop           stop it and reap it
#
# The sampler is a subshell whose children - the ioreg pipeline, the sleep -
# outlive it if only it is killed. So it stops its own child on TERM, and its
# sleep is waited on rather than run in the foreground, so the TERM is taken
# at once rather than after the sleep. The caller traps EXIT, TERM and INT to
# stop it, so no way out of the caller leaves a sampler behind.
gpusampler_pid=""

gpusampler_start() {
    gpusampler_stop
    ( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
      while :; do
          ioreg -r -d 1 -c IOAccelerator | grep -o '"PerformanceStatistics" = {[^}]*}' |
            tr ',' '\n' | grep -E 'Renderer Utilization|Tiler Utilization|Device Utilization' |
            tr -dc '0-9\n' | tr '\n' ' '; echo
          sleep 5 & wait $!
      done ) > "$1" 2>/dev/null &
    gpusampler_pid=$!
}

gpusampler_stop() {
    [ -n "$gpusampler_pid" ] || return 0
    kill -TERM "$gpusampler_pid" 2>/dev/null
    wait "$gpusampler_pid" 2>/dev/null
    gpusampler_pid=""
}
