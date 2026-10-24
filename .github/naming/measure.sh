#!/bin/bash
# DIAGNOSTIC ONLY (naming branch).  Run from the build directory.
#
# How often does Thread#name= run while the new thread's nt->thread_id is
# still 0, and does test_thread_name_set_before_start catch a missing guard?
# SETNAME_DIAG (see rb_thread_setname): "count" prints SETNAME_ZERO on the
# zero-id path; "noguard" also calls pthread_setname_np with the 0 id, as the
# code would without the guard.  Unset is the PR's code.
set -u
here=$(cd "$(dirname "$0")" && pwd)
N=${N:-500}
H=${H:-50}
export RUBY_MN_THREADS=0
cpu=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*\([0-9]*\).*/\1/p' /proc/self/status)
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}

{
  echo "### $(uname -m), nproc $(nproc), $(ldd --version | head -1)"
  echo "$(taskset --version 2>&1 | head -1); pinned runs use CPU $cpu"
  echo
} | tee -a "$summary"

# A-C: the test body as a script, $N runs each
{
  echo "| SETNAME_DIAG | pinned | runs with a zero id | zero-id name= calls | crashed | mismatch | clean |"
  echo "|---|---|---|---|---|---|---|"
} | tee -a "$summary"
for diag in count noguard ""; do
  for pin in no yes; do
    diagenv=(SETNAME_DIAG="$diag")
    [ -z "$diag" ] && diagenv=(-u SETNAME_DIAG)
    pre=()
    [ $pin = yes ] && pre=(taskset -c "$cpu")
    zero_runs=0 zeros=0 crashed=0 mismatch=0 clean=0
    for _ in $(seq "$N"); do
      out=$(env "${diagenv[@]}" "${pre[@]}" ./miniruby "$here/S.rb" 2>&1)
      st=$?
      z=$(grep -c "^SETNAME_ZERO name" <<<"$out")
      zeros=$((zeros + z))
      [ "$z" -gt 0 ] && zero_runs=$((zero_runs + 1))
      if grep -q MISMATCH <<<"$out"; then
        mismatch=$((mismatch + 1))
      elif [ $st -ne 0 ]; then
        crashed=$((crashed + 1))
        [ $crashed -eq 1 ] && printf '%s\n' "$out" | head -20 > "crash-${diag:-final}-$pin.txt"
      else
        clean=$((clean + 1))
      fi
    done
    echo "| ${diag:-(unset)} | $pin | $zero_runs/$N | $zeros/$((N * 10)) | $crashed | $mismatch | $clean |" | tee -a "$summary"
  done
done

# D: the real tests through the test runner, $H runs each
RUNRUBY="./miniruby -I../src/lib -I. -I.ext/common ../src/tool/runruby.rb --extout=.ext --"
{
  echo
  echo "| test | SETNAME_DIAG | passed | failed |"
  echo "|---|---|---|---|"
} | tee -a "$summary"
for name in test_thread_name_set_before_start test_thread_name_set_before_start_pinned; do
  for diag in noguard ""; do
    diagenv=(SETNAME_DIAG="$diag")
    [ -z "$diag" ] && diagenv=(-u SETNAME_DIAG)
    pass=0 fail=0
    for _ in $(seq "$H"); do
      if env "${diagenv[@]}" $RUNRUBY -r../src/tool/lib/_tmpdir ../src/test/runner.rb --ruby="$RUNRUBY" \
           --excludes-dir=../src/test/.excludes -q --tty=no ruby/test_thread.rb -n "$name" > runner.log 2>&1; then
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
        [ $fail -eq 1 ] && cp runner.log "runner-$name-${diag:-final}.log"
      fi
    done
    echo "| $name | ${diag:-(unset)} | $pass | $fail |" | tee -a "$summary"
  done
done

# The PR's code: the whole file once
echo | tee -a "$summary"
$RUNRUBY -r../src/tool/lib/_tmpdir ../src/test/runner.rb --ruby="$RUNRUBY" \
  --excludes-dir=../src/test/.excludes -q --tty=no ruby/test_thread.rb 2>&1 | tee test_thread.log | tail -3
echo "test_thread.rb: $(grep -E '^[0-9]+ tests' test_thread.log)" | tee -a "$summary"
