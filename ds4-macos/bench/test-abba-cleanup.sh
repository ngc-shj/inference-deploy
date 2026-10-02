#!/bin/bash
# Leaves m4abba.sh nothing to leave behind: every way out of a run - normal
# end, TERM or INT to the script alone mid-arm, a server that fails in every
# arm - must end with its process group empty, without gpurun.sh to clean up.
#
#   test-abba-cleanup.sh        prints one line a case, exits 1 if any leaks
#
# Touches no GPU: the scripts are copied beside fake servers that are, like the
# real one, a single process - one that answers, one that never listens, one
# that exits at once.
set -u
S=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bench" "$D/bin_ok" "$D/bin_slow" "$D/bin_err"
cp "$S/m4abba.sh" "$S/gpusampler.sh" "$S/sustained.sh" "$S/thermal" "$S/cputicks" "$D/bench/"
printf '#!/bin/bash\necho "listening on 127.0.0.1"; exec sleep 1000\n' > "$D/bin_ok/ds4-server"
printf '#!/bin/bash\nexec sleep 1000\n' > "$D/bin_slow/ds4-server"
printf '#!/bin/bash\nexit 1\n' > "$D/bin_err/ds4-server"
for v in ok slow err; do
    chmod +x "$D/bin_$v/ds4-server"
    (cd "$D/bin_$v" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x)
done
fail=0
check() {
    sleep 3
    local n; n=$(pgrep -g "$1" | wc -l | tr -d ' ')
    if [ "$n" = 0 ]; then echo "PASS $2"; else
        echo "FAIL $2: $n process(es) left:"; ps -o pid,command -g "$1" | tail -n +2
        for x in $(pgrep -g "$1"); do kill "$x" 2>/dev/null; done
        fail=1
    fi
}
run() {   # name bin port [signal]
    set -m
    ( cd "$D/bench" && PORT=$3 NOGATE=1 BIN_A=$D/$2 BIN_B=$D/$2 exec ./m4abba.sh "t$1" 1 ) \
        > "$D/$1.out" 2>&1 &
    local p=$!
    set +m
    if [ -n "${4:-}" ]; then sleep 8; kill "-$4" "$p"; fi
    wait "$p"
    check "$p" "$1"
}
run normal bin_ok 8091
run term bin_slow 8092 TERM
run int bin_slow 8093 INT
run error bin_err 8094
exit $fail
