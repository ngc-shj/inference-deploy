#!/bin/bash
# The fifteen acceptance items of ../V4.1-METAL4-NATIVE.md, checked from the
# engine source and from the run records - nothing is run on the GPU here.
#
#   m4accept.sh <tag>      reads the runs named after <tag>:
#     gpurun-paths<T>.log / m4-p<T>-*  m4paths.sh p<T> (all steps)
#     m4st-st<T>.hashes, m4st-st<T>4.*  m4state.sh, plain and PARTS=4
#     gpurun-in<T>.log                  m4inproc.sh EXPECT=1 STEPS=2048
#     capab-<T>-long*.f32               m4capab.sh at several cache sizes
#     gpurun-bud<T>.log                 m4budget.sh
#     m4ab-abba-<t>/                    the final ABBA (abba-judge.py)
#   DS4_BIN  the engine tree (default ds4-v41-m4native); every record must
#            name its HEAD with dirty 0
#
# Prints PASS or FAIL per item with the evidence it read, and exits 1 unless
# all fifteen pass.
set -u
S=$(cd "$(dirname "$0")" && pwd)
T=${1:?usage: m4accept.sh <tag>}
t=$(printf '%s' "$T" | tr '[:upper:]' '[:lower:]')
C=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
REV=$(git -C "$C" rev-parse HEAD)
cd "$S"
pass=0
item() {   # n verdict text
    if [ "$2" = 1 ]; then echo "PASS $1  $3"; pass=$((pass + 1)); else echo "FAIL $1  $3"; fi
}
src() { grep -c -E "$1" "$C/ds4_metal.m" "$C/ds4_metal_mtl4.h" "$C/ds4.c" | awk -F: '{s += $2} END {print s + 0}'; }
logs="gpurun-paths$T.log gpurun-in$T.log"

# Every record is of this revision, clean, and of the binary the tree holds
# now; every GPU run under it exited 0, unstopped, at pressure level 1.
stale=0
sha() { shasum -a 256 "$C/$1" | cut -d' ' -f1; }
rec() {   # record-file binary-in-tree gpurun-name
    local f=$1 want; want=$(sha "$2")
    [ -f "$f" ] || { echo "missing record $f"; stale=1; return; }
    local one; one=$(tr '\n' ' ' < "$f")
    printf '%s' "$one" | grep -q "rev $REV" || { echo "$f: not rev $REV"; stale=1; }
    printf '%s' "$one" | grep -q "dirty 0" || { echo "$f: dirty"; stale=1; }
    printf '%s' "$one" | grep -q "binary $want" || { echo "$f: binary is not the tree's $2"; stale=1; }
    [ -n "${3:-}" ] || return
    local g=gpurun-$3.prov
    grep -q "^rc 0 .*peak pressure level 1," "$g" 2>/dev/null || { echo "$g: not rc 0 at pressure level 1"; stale=1; }
    grep -qE '^(ASKED|KILLED)' "$g" 2>/dev/null && { echo "$g: stopped by the guard"; stale=1; }
}
for x in prod tl lg; do rec m4-p$T-$x.prov ds4-server; done
for x in nat fb fa; do rec m4b-p$T-$x.prov ds4-server; done
rec m4kv-p$T-kv.prov ds4-server; rec m4v-p$T-v.prov ds4-server; rec m4-p$T-exec.prov ds4-server paths$T
rec m4st-st$T.prov tests/test_deepseek41_state st$T
rec m4st-st${T}4.prov tests/test_deepseek41_state st${T}4
rec m4in-in$T.prov tests/test_deepseek41_backend in$T
rec gpurun-bud$T.rev tests/test_deepseek41_budget bud$T
for f in capab-$T-long*.prov; do n=${f#capab-}; rec "$f" tests/test_deepseek41_capacity "cap-${n%.prov}"; done
for f in m4ab-abba-$t/0*-mb.prov; do rec "$f" ds4-server; done
grep -q "^rc 0 .*peak pressure level 1," gpurun-abba$t.prov 2>/dev/null || { echo "gpurun-abba$t.prov: not rc 0 at pressure level 1"; stale=1; }
[ "$stale" = 0 ] && echo "records: every one is $REV, dirty 0, the tree's binaries, rc 0 at pressure level 1" ||
    echo "records: STALE - the items below do not describe $REV"

# Census lines: one per server run and test, all must read zero.
m3=$(cat $logs | grep -h "Metal 3 command execution after Metal 4 selection" | grep -cv "selection: 0 (refused [01]); Metal 3 queues created before selection 0, after 0")
m3n=$(cat $logs | grep -hc "Metal 3 command execution after Metal 4 selection")
unst=$(cat $logs | grep -h "bindings with no stated length" | grep -cv "length: 0 at 0")
unstn=$(cat $logs | grep -hc "bindings with no stated length")
item 1 $([ "$m3" = 0 ] && [ "$m3n" -gt 0 ] && echo 1) "no Metal 3 queue created in $m3n census lines (paths$T, in$T)"
item 2 $([ "$(src 'g_batch_cb([^_]|$)')" = 0 ] && echo 1) "g_batch_cb: $(src 'g_batch_cb([^_]|$)') references"
item 3 $([ "$(src 'DS4Encoder|DS4MTL4Encoder')" = 0 ] && echo 1) "DS4Encoder / DS4MTL4Encoder: $(src 'DS4Encoder|DS4MTL4Encoder') references"
ctx=$(grep -h "contexts in .* command buffers" m4-p$T-prod.log 2>/dev/null | tail -1)
item 4 $([ -n "$ctx" ] && [ "$(src '@interface DS4M4Ctx')" -ge 1 ] && echo 1) "DS4M4Ctx; prod: ${ctx:0:90}"
own=0
for f in 'id<MTL4CommandAllocator>' 'id<MTL4CommandBuffer>' 'id<MTL4ArgumentTable>' 'id<MTLBuffer> scratch' 'id<MTLResidencySet>' 'fb_stamp'; do
    awk '/@interface DS4M4Ctx/,/@end/' "$C/ds4_metal_mtl4.h" | grep -q -- "$f" && own=$((own + 1))
done
item 5 $([ "$own" = 6 ] && echo 1) "DS4M4Ctx holds $own of 6: allocator, command buffer, argument table, scratch, residency set, feedback"
item 6 $([ "$(src '^static .*MTL4ArgumentTable')" = 0 ] && [ "$(src 'g_mtl4_table')" = 0 ] && echo 1) "global argument tables: $(src '^static .*MTL4ArgumentTable')"
item 7 $([ "$unst" = 0 ] && [ "$unstn" -gt 0 ] && [ "$(src 'uint32_t gen')" -ge 1 ] && echo 1) "every binding states its range in $unstn census lines; ranges carry a generation"
bar=$(grep -h "barriers .* from the graph" m4-p$T-prod.log 2>/dev/null | tail -1)
item 8 $([ -n "$bar" ] && echo 1) "prod: $(printf '%s' "$bar" | grep -o 'barriers [0-9.]* from the graph[^;]*')"
p4=$(diff m4st-frozen-m3.hashes <(grep -v '^parts' m4st-st${T}4.hashes) > /dev/null 2>&1 && echo 1)
item 9 $([ "$p4" = 1 ] && [ "$(src 'commit:list count:parts')" -ge 1 ] && echo 1) "every context cut in 4 parts, encoded on worker threads, commit:count: - state hashes equal the baseline's"
fa=$(grep -A4 "== full address table formally removed" gpurun-paths$T.log | grep -c "0 differ")
tl=$(grep -h "m4-p$T-tl.json vs" gpurun-paths$T.log | grep -c "0 differ")
item 10 $([ "$(src 'ds41_expert_pin_windows|resident_service|DS4_METAL_V41_RESIDENT_LAYER')" = 0 ] && [ "$fa" = 1 ] && [ "$tl" = 1 ] && echo 1) "full table and resident layer removed (0 references, fa step matches); timeline on MTL4CounterHeap matches"
steps=$(grep -hcE "0 differ|kv bytes identical" gpurun-paths$T.log)
st21=$(grep -h "self-tests:" gpurun-paths$T.log | tail -1)
inj=$(grep -cE "^(after .* 128 of 128|reopen .* 2048 of 2048)" gpurun-in$T.log)
item 11 $([ "$steps" -ge 8 ] && [ "$inj" = 2 ] && [ "$st21" = "self-tests: 21 passing lines, 0 failing, 0 not run" ] && echo 1) "prod, native and fallback batch, disk KV, vision, timeline, ledger match ($steps); $st21; failure and reopen paths"
item 12 $([ "$m3" = 0 ] && [ "$(grep -h '^fallback' gpurun-in$T.log)" = "fallback   Metal 3 work noted under the Metal 4 backend: 0" ] && echo 1) "Metal 3 execution 0 in every census; Metal 3 work under Metal 4: 0"
st=$(diff m4st-frozen-m3.hashes m4st-st$T.hashes > /dev/null 2>&1 && echo 1)
orc=$(grep -c "as before" gpurun-in$T.log)
item 13 $([ "$st" = 1 ] && [ "$orc" = 3 ] && echo 1) "ids, every logit and the saved KV/carry state equal the frozen baseline's in all 8 cases; in-process ids on the clean oracle (3/3)"
# Long prompt at each cache size: the frozen baseline's production ids, every
# logit and saved state (m4st-frozen-m3 "long"), one token-major tail of 699
# rows at 4096, and byte-identical logit files.
want=$(awk '$1 == "long" {print $7, $9, $11}' m4st-frozen-m3.hashes)
ref=$(ls capab-$T-long*.f32 2>/dev/null | head -1); same=1; n=0; sizes=""
for f in capab-$T-long*.f32; do
    [ -f "$f" ] || continue
    l=${f%.f32}.log; n=$((n + 1))
    sizes="$sizes $(sed -n 's/^capacity \([0-9]*\) experts.*/\1/p' "$l")"
    cmp -s "$ref" "$f" || same=0
    got=$(sed -n 's/^capacity.* ids \([0-9a-f]*\), logits \([0-9a-f]*\), state \([0-9a-f]*\).*/\1 \2 \3/p' "$l")
    [ "$got" = "$want" ] || { echo "$l: ids/logits/state $got, baseline $want"; same=0; }
    [ "$(grep -c 'prefill tail of 699 rows at position 4096 runs token-major' "$l")" = 1 ] ||
        { echo "$l: not exactly one 699-row tail"; same=0; }
done
for c in 4096 5400 10268; do printf '%s' " $sizes " | grep -q " $c " || { echo "no long run at cache $c"; same=0; }; done
bud=$(diff <(grep "^ids" gpurun-budD.log) <(grep "^ids" gpurun-bud$T.log) > /dev/null && echo 1)
item 14 $([ "$st" = 1 ] && [ "$same" = 1 ] && [ "$bud" = 1 ] && echo 1) "2048 tokens, 3 prompts, 2 sessions, 3 consecutive requests; long prompt at caches$sizes: baseline ids, logits and state, one 699-row tail each; 4-session budget"
judge=$(python3 abba-judge.py "m4ab-abba-$t" "gpurun-abba$t.samples" 7041 2>/dev/null)
abba=$(printf '%s\n' "$judge" | tail -1)
tails=$(printf '%s\n' "$judge" | sed -n 's/^token-major prefill tails in b arms: \([0-9]*\).*/\1/p')
ok15=0
case "$abba" in "decision: no regression"|"decision: improvement"*) ok15=1 ;; esac
printf '%s\n' "$judge" | grep -q "INVALID" && ok15=0
[ "$(printf '%s\n' "$judge" | grep -c ' valid$')" = 8 ] || ok15=0
item 15 "$ok15" "ABBA m4ab-abba-$t, b on $REV: 8 valid arms, same text and token ids in all; changed prefill path taken ${tails:-?} times; ${abba:-none}"
echo "$pass of 15"
[ "$pass" = 15 ] && [ "$stale" = 0 ]
