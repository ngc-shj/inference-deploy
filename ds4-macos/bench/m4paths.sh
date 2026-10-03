#!/bin/bash
# Every single-host V4.1 path on a candidate build, against the frozen Metal 3
# baseline's outputs of the same scripts.
#
#   m4paths.sh <tag> [step...]      steps: prod nat fb kv vision fa exec tl lg
#   DS4_BIN=candidate tree (default ds4-v41-m4native)
set -u
S=$(cd "$(dirname "$0")" && pwd)
TAG=${1:?usage: m4paths.sh <tag> [step...]}; shift
C=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
F=$HOME/ghq/github.com/antirez/ds4-v41-frozen
STEPS=${*:-prod nat fb kv vision fa exec tl lg}
cd "$S"
cmpjson() {
    python3 -c "import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); ks=sorted(set(a)&set(b)); bad=[k for k in ks if a[k]!=b[k]]; print('%s vs %s: %d compared, %d differ %s' % (sys.argv[1], sys.argv[2], len(ks), len(bad), bad))" "$1" "$2"
}
census() {
    grep "bindings with no stated length" "$1" | tail -1
    grep "Metal 3 command execution after Metal 4 selection" "$1" | tail -1
}
for s in $STEPS; do
case $s in
prod) echo "== prod"; DS4_BIN=$C ./m4prod.sh $TAG-prod 4 > /dev/null 2>&1
      cmpjson m4-$TAG-prod.json co-mainref2.json; census m4-$TAG-prod.log ;;
nat) echo "== native batch"; DS4_BIN=$C ./m4batch.sh $TAG-nat DS4_METAL_ENABLE_V41_STREAMING_SESSION_BATCH=1 > /dev/null 2>&1
     cmpjson m4b-$TAG-nat.json m4b-nat-m3.json; diff -q m4b-$TAG-nat.ids m4b-nat-m3.ids && echo "ids identical"
     cat m4b-$TAG-nat.path; census m4b-$TAG-nat.log ;;
fb) echo "== fallback batch"; DS4_BIN=$C ./m4batch.sh $TAG-fb > /dev/null 2>&1
    cmpjson m4b-$TAG-fb.json m4b-fb-m3.json; diff -q m4b-$TAG-fb.ids m4b-fb-m3.ids && echo "ids identical"; census m4b-$TAG-fb.log ;;
kv) echo "== disk kv"; DS4_BIN=$C ./m4kv.sh $TAG-kv > /dev/null 2>&1
    cmp -s m4kv-$TAG-kv-1.txt m4kv-kv-m3-1.txt && cmp -s m4kv-$TAG-kv-2.txt m4kv-kv-m3-2.txt && echo "kv bytes identical" || echo "kv bytes DIFFER"
    diff -q m4kv-$TAG-kv.ids m4kv-kv-m3.ids && echo "ids identical"; grep -h "kv cache hit" m4kv-$TAG-kv-b.log | head -1 | cut -c1-80
    census m4kv-$TAG-kv-b.log ;;
vision) echo "== vision"; DS4_BIN=$C ./m4vision.sh $TAG-v > /dev/null 2>&1
        cmpjson m4v-$TAG-v.json m4v-v-m3.json; diff -q m4v-$TAG-v.ids m4v-v-m3.ids && echo "ids identical"; census m4v-$TAG-v.log ;;
fa) echo "== full address table formally removed"
    # The Metal 3 full table's native-batch output was wrong, so it is no
    # oracle. With the old switch set, the native batch must still match the
    # ordinary Metal 3 native batch, and nothing may reach a table or window.
    grep -q "ds41_expert_pin_windows" "$C/ds4.c" && echo "FAIL: pin windows still in ds4.c"
    DS4_BIN=$C ./m4batch.sh $TAG-fa DS4_METAL_ENABLE_V41_STREAMING_SESSION_BATCH=1 DS4_METAL_ENABLE_STREAMING_FULL_EXPERT_ADDR_TABLE=1 > /dev/null 2>&1
    cmpjson m4b-$TAG-fa.json m4b-nat-m3.json; diff -q m4b-$TAG-fa.ids m4b-nat-m3.ids && echo "ids identical"
    grep -h "pinned windows" m4b-$TAG-fa.log && echo "FAIL: a pinned window opened"
    census m4b-$TAG-fa.log ;;
exec) echo "== executor"
      # The self-tests exercise the block executor, its transaction and the
      # device's residency check: without those switched on they test another
      # path and report FAIL and MISMATCH against expectations written for this
      # one (they now refuse with NOT RUN instead). The cache is 6144, which
      # the memory budget never fits, so the frozen build, which has no budget,
      # can run the same command.
      ONLY=haiku DS4_BIN=$C DS4_EXTRA_ARGS="--ssd-streaming-cache-experts 6144" ./m4prod.sh $TAG-exec 4 \
          DS4_METAL_V41_MTL4=2 DS4_V41_BLOCK_DAG_TEST=1 DS4_V41_BLOCK_TXN_TEST=1 DS4_V41_FORCE_MISS_TEST=1 \
          DS4_V41_BLOCK_TXN_CHAIN=1 DS4_METAL_V41_BLOCK=1 DS4_METAL_V41_BLOCK_TXN=1 \
          DS4_METAL_V41_BLOCK_RESIDENCY=1 > /dev/null 2>&1
      echo "candidate $(cat m4-$TAG-exec.ids)"; echo "frozen    $(cat m4-exec-self-frozen.ids)"
      echo "self-tests: $(grep -c 'logits identical\|-> PASS\|match their single-step\|matches its references' m4-$TAG-exec.log) passing lines, $(grep -c 'FAIL\|MISMATCH\|DIFF' m4-$TAG-exec.log) failing, $(grep -c 'NOT RUN' m4-$TAG-exec.log) not run"
      census m4-$TAG-exec.log ;;
tl) echo "== timeline"; rm -f m4-$TAG-tl.timeline
    ONLY=haiku DS4_BIN=$C ./m4prod.sh $TAG-tl 4 DS4_METAL_ENCODER_TIMELINE=$S/m4-$TAG-tl.timeline > /dev/null 2>&1
    cmpjson m4-$TAG-tl.json co-mainref2.json; echo "E lines $(grep -c '^E ' m4-$TAG-tl.timeline) B lines $(grep -c '^B ' m4-$TAG-tl.timeline)"
    grep '^E ' m4-$TAG-tl.timeline | sed -n 100p ;;
lg) echo "== ledger"; rm -f m4-$TAG-lg.ledger
    ONLY=haiku DS4_BIN=$C ./m4prod.sh $TAG-lg 4 DS4_METAL_LEDGER=$S/m4-$TAG-lg.ledger > /dev/null 2>&1
    cmpjson m4-$TAG-lg.json co-mainref2.json; ls -la m4-$TAG-lg.ledger 2>&1 | awk '{print "ledger bytes", $5}'
    head -c 400 m4-$TAG-lg.ledger 2>/dev/null; echo ;;
esac
done
echo ALL-DONE
