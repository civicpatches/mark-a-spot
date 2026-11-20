#!/bin/sh
# Exercise the background loops of docker/runtime/docker-entrypoint.sh with
# fake commands: no container, no database and no real sleeps.
#
# Usage:
#   sh scripts/test-runtime-entrypoint.sh
#   TEST_SH=dash sh scripts/test-runtime-entrypoint.sh
#   TEST_SH="busybox ash" sh scripts/test-runtime-entrypoint.sh
#
# TEST_SH names the shell that runs the entrypoint and the loop bodies. CI runs
# this script with dash and with BusyBox ash from the PHP Alpine base image.
#
# Fake commands and loop preludes are shell code for another shell, so their
# variables are meant to stay unexpanded here.
# shellcheck disable=SC2016
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
entrypoint="$script_dir/../docker/runtime/docker-entrypoint.sh"

# Resolve the shell under test before fake commands appear on PATH.
# shellcheck disable=SC2086
set -- ${TEST_SH:-sh}
test_sh=$(command -v "$1") || {
  echo "Shell under test not found: $1" >&2
  exit 2
}
shift
test_sh_args="$*"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' HUP INT TERM

checks=0
failures=0

# expect_eq <label> <expected> <actual>
expect_eq() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    failures=$((failures + 1))
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
  fi
}

# count <file> <fixed string>: number of lines that contain the string.
count() {
  if [ -f "$1" ]; then
    grep -c -F -- "$2" "$1" || true
  else
    echo 0
  fi
}

# count_lines <file> <fixed string>: number of lines equal to the string.
count_lines() {
  if [ -f "$1" ]; then
    grep -c -x -F -- "$2" "$1" || true
  else
    echo 0
  fi
}

queue_call='queue:run markaspot_media_intake --time-limit=50 --lease-time=900'
probe_source='echo \Drupal::service("plugin.manager.queue_worker")->hasDefinition("markaspot_media_intake") ? "media-intake-worker=available" : "media-intake-worker=missing";'

# ---------------------------------------------------------------------------
# Part 1: which containers start the loops.
#
# A copy of the entrypoint runs with its container paths moved into the work
# directory. Fake id reports root, so the loops go through su-exec, which only
# records its arguments. The loop bodies therefore never run here.
# ---------------------------------------------------------------------------

fake_bin="$work/bin"
mkdir -p "$fake_bin" "$work/tmp"

write_fake() {
  printf '#!/bin/sh\n%s\n' "$2" > "$fake_bin/$1"
  chmod 0755 "$fake_bin/$1"
}

write_fake id 'if [ "${1:-}" = -u ]; then echo 0; else exit 64; fi'
write_fake chown 'exit 0'
write_fake su-exec 'printf "CALL su-exec %s\n" "$*" >> "$EVENTS"'
write_fake php-fpm 'printf "CALL php-fpm %s\n" "$*" >> "$EVENTS"'

sed -e "s#/app/data#$work/app#g" -e "s#/tmp/#$work/tmp/#g" "$entrypoint" > "$work/entrypoint.sh"

# run_entrypoint <case> <MARKASPOT_CRON_ENABLED|UNSET> <MARKASPOT_CRON_INTERVAL|UNSET> <command...>
# Sets status, events and stderr. stdout is a pipe that background children
# inherit, so the command substitution also waits for every started loop.
run_entrypoint() {
  case_dir="$work/entry-$1"
  cron=$2
  interval=$3
  shift 3
  mkdir -p "$case_dir"
  events="$case_dir/events"
  stderr="$case_dir/stderr"
  : > "$events"
  set -- "$work/entrypoint.sh" "$@"
  # shellcheck disable=SC2086
  set -- "$test_sh" $test_sh_args "$@"
  if [ "$interval" != UNSET ]; then
    set -- "MARKASPOT_CRON_INTERVAL=$interval" "$@"
  fi
  if [ "$cron" != UNSET ]; then
    set -- "MARKASPOT_CRON_ENABLED=$cron" "$@"
  fi
  output=$(
    if env -i "PATH=$fake_bin:$PATH" "EVENTS=$events" \
        DRUPAL_HASH_SALT=0123456789abcdef0123456789abcdef "$@" 2> "$stderr"; then
      echo "STATUS=0"
    else
      echo "STATUS=$?"
    fi
  )
  status=${output##*STATUS=}
}

expect_no_loops() {
  expect_eq "$1: exit status" 0 "$status"
  expect_eq "$1: background loops" 0 "$(count "$events" 'sh -lc')"
}

for value in UNSET '' false; do
  run_entrypoint "cron-[$value]" "$value" UNSET php-fpm -F
  expect_no_loops "MARKASPOT_CRON_ENABLED=[$value]"
  expect_eq "MARKASPOT_CRON_ENABLED=[$value]: php-fpm started" 1 "$(count_lines "$events" 'CALL php-fpm -F')"
done

run_entrypoint disabled-bad-interval false abc php-fpm -F
expect_no_loops "disabled cron ignores MARKASPOT_CRON_INTERVAL"

run_entrypoint enabled true UNSET php-fpm -F
expect_eq "enabled php-fpm: exit status" 0 "$status"
expect_eq "enabled php-fpm: background loops" 2 "$(count "$events" 'sh -lc')"
expect_eq "enabled php-fpm: cron loop as app with default interval" 1 \
  "$(count "$events" 'CALL su-exec app env MARKASPOT_CRON_INTERVAL=900 sh -lc')"
expect_eq "enabled php-fpm: media intake runner as app" 1 "$(count "$events" 'CALL su-exec app sh -lc')"
expect_eq "enabled php-fpm: cron body" 1 "$(count "$events" './vendor/bin/drush cron')"
expect_eq "enabled php-fpm: media intake body" 1 "$(count "$events" "$queue_call")"
expect_eq "enabled php-fpm: php-fpm started" 1 "$(count_lines "$events" 'CALL php-fpm -F')"

run_entrypoint interval true 120 php-fpm -F
expect_eq "custom interval: cron loop" 1 "$(count "$events" 'CALL su-exec app env MARKASPOT_CRON_INTERVAL=120 sh -lc')"

for command in 'drush updatedb -y' 'drush deploy'; do
  # shellcheck disable=SC2086
  run_entrypoint "one-off-$command" true UNSET $command
  expect_no_loops "one-off [$command] with cron enabled"
  expect_eq "one-off [$command]: runs as app" 1 "$(count_lines "$events" "CALL su-exec app $command")"
  expect_eq "one-off [$command]: no php-fpm" 0 "$(count "$events" 'CALL php-fpm')"
done

run_entrypoint invalid-switch yes UNSET php-fpm -F
expect_eq "MARKASPOT_CRON_ENABLED=yes: exit status" 1 "$status"
expect_eq "MARKASPOT_CRON_ENABLED=yes: message" 1 "$(count "$stderr" 'MARKASPOT_CRON_ENABLED must be true or false')"
expect_eq "MARKASPOT_CRON_ENABLED=yes: nothing started" 0 "$(count "$events" 'CALL')"

for interval in 59 86401 abc 0900000; do
  run_entrypoint "invalid-interval-$interval" true "$interval" php-fpm -F
  expect_eq "MARKASPOT_CRON_INTERVAL=$interval: exit status" 1 "$status"
  expect_eq "MARKASPOT_CRON_INTERVAL=$interval: message" 1 \
    "$(count "$stderr" 'MARKASPOT_CRON_INTERVAL must be an integer from 60 to 86400')"
  expect_eq "MARKASPOT_CRON_INTERVAL=$interval: nothing started" 0 "$(count "$events" 'CALL')"
done

# ---------------------------------------------------------------------------
# Part 2: the loop bodies themselves, with fake sleep, date and Drush.
# ---------------------------------------------------------------------------

expect_eq "entrypoint: background loop definitions" 2 "$(count "$entrypoint" "sh -lc '")"

# extract_loop <n>: body of the n-th "sh -lc '" block, container root remapped.
extract_loop() {
  awk -v want="$1" '
    /sh -lc '\''$/ { n++; if (n == want) { grab = 1; next } }
    grab && /^[[:space:]]*'\'' &$/ { exit }
    grab { print }
  ' "$entrypoint" | sed 's#/app/data#"$TEST_ROOT"#g'
}

extract_loop 1 > "$work/cron-body.sh"
extract_loop 2 > "$work/media-body.sh"
for body in cron-body media-body; do
  expect_eq "$body: no single quote inside the loop body" 0 "$(count "$work/$body.sh" "'")"
done
expect_eq "cron body: runs drush cron" 1 "$(count "$work/cron-body.sh" './vendor/bin/drush cron')"
expect_eq "media body: runs the queue worker" 1 "$(count "$work/media-body.sh" "$queue_call")"

cat > "$work/fake-drush" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
case "$1" in
  cron)
    echo "cron output"
    echo "cron warning" >&2
    exit "$CRON_EXIT"
    ;;
  php:eval)
    index=0
    if [ -f "$TEST_ROOT/probes" ]; then
      index=$(cat "$TEST_ROOT/probes")
    fi
    echo $((index + 1)) > "$TEST_ROOT/probes"
    # PROBE_RESULTS lists answer:exit pairs, one per probe; the last repeats.
    position=0
    result=
    for result in $PROBE_RESULTS; do
      if [ "$position" -eq "$index" ]; then
        break
      fi
      position=$((position + 1))
    done
    answer=${result%%:*}
    code=${result##*:}
    echo "probe diagnostic stdout"
    echo "probe diagnostic stderr" >&2
    case "$answer" in
      echo-source)
        # Defensive case: a tool that echoes the eval source with exit 0.
        printf '%s\n' "$2"
        ;;
      no-marker) ;;
      abnormal)
        # Drush 13: exit() inside php:eval, or any fatal, ends abnormally.
        echo " [warning] Drush command terminated abnormally." >&2
        ;;
      missing-then-available)
        printf 'media-intake-worker=missing\nmedia-intake-worker=available\n'
        ;;
      available-then-missing)
        printf 'media-intake-worker=available\nmedia-intake-worker=missing\n'
        ;;
      *)
        echo "media-intake-worker=$answer"
        ;;
    esac
    exit "$code"
    ;;
  queue:run)
    clock=$(cat "$TEST_ROOT/clock")
    echo $((clock + QUEUE_SECONDS)) > "$TEST_ROOT/clock"
    echo "queue worker output"
    echo "queue worker error" >&2
    exit "$QUEUE_EXIT"
    ;;
esac
echo "unexpected drush call: $*" >&2
exit 64
EOF
chmod 0755 "$work/fake-drush"

setup_loop_root() {
  loop_root="$work/loop-$1"
  mkdir -p "$loop_root/vendor/bin"
  cp "$work/fake-drush" "$loop_root/vendor/bin/drush"
  echo 0 > "$loop_root/clock"
  : > "$loop_root/calls"
  calls="$loop_root/calls"
  out="$loop_root/stdout"
  err="$loop_root/stderr"
}

# The fake sleep ends the loop after ITERATIONS passes.
cron_prelude='ticks=0
sleep() {
  [ "$1" = "$EXPECT_SLEEP" ] || { echo "unexpected sleep $1" >&2; exit 91; }
  ticks=$((ticks + 1))
  if [ "$ticks" -gt "$ITERATIONS" ]; then exit 0; fi
}
'

# run_cron_loop <case> <drush cron exit> <interval> <passes>
run_cron_loop() {
  setup_loop_root "cron-$1"
  # shellcheck disable=SC2086
  if env TEST_ROOT="$loop_root" CRON_EXIT="$2" MARKASPOT_CRON_INTERVAL="$3" \
      EXPECT_SLEEP="$3" ITERATIONS="$4" \
      "$test_sh" $test_sh_args -c "$cron_prelude$(cat "$work/cron-body.sh")" \
      > "$out" 2> "$err"; then
    status=0
  else
    status=$?
  fi
  expect_eq "cron $1: loop exit status" 0 "$status"
  expect_eq "cron $1: drush cron calls" "$4" "$(count_lines "$calls" cron)"
  expect_eq "cron $1: drush stdout reaches the log" "$4" "$(count "$out" 'cron output')"
  expect_eq "cron $1: drush stderr reaches the log" "$4" "$(count "$err" 'cron warning')"
}

run_cron_loop success 0 900 2
expect_eq "cron success: no failure line" 00 "$(count "$out" failed)$(count "$err" failed)"
for code in 1 255; do
  run_cron_loop "failure-$code" "$code" 900 2
  expect_eq "cron failure-$code: failure line with exit code" 2 \
    "$(count_lines "$err" "Drupal cron failed (exit $code); next attempt in 900 seconds")"
  expect_eq "cron failure-$code: nothing on stdout but drush output" 2 "$(grep -c . "$out" || true)"
done
run_cron_loop custom-interval 1 120 3
expect_eq "cron custom-interval: failure line names the interval" 3 \
  "$(count_lines "$err" 'Drupal cron failed (exit 1); next attempt in 120 seconds')"

# The fake clock advances by the slept seconds and by QUEUE_SECONDS per queue
# run. The first sleep is the 60 second start delay; later sleeps must be the
# rest of the minute. A runaway guard stops a loop that never sleeps.
media_prelude='ticks=0
date() {
  [ "$1" = +%s ] || exit 92
  reads=0
  if [ -f "$TEST_ROOT/date-reads" ]; then reads=$(cat "$TEST_ROOT/date-reads"); fi
  reads=$((reads + 1))
  echo "$reads" > "$TEST_ROOT/date-reads"
  if [ "$reads" -gt $((ITERATIONS * 2 + 4)) ]; then
    echo "runaway media intake loop" >&2
    kill -TERM $$
  fi
  cat "$TEST_ROOT/clock"
}
sleep() {
  ticks=$((ticks + 1))
  if [ "$ticks" -eq 1 ]; then
    [ "$1" = 60 ] || { echo "unexpected start delay $1" >&2; exit 91; }
  else
    [ "$1" = "$EXPECT_DELAY" ] || { echo "unexpected sleep $1" >&2; exit 93; }
  fi
  clock=$(cat "$TEST_ROOT/clock")
  echo $((clock + $1)) > "$TEST_ROOT/clock"
  if [ "$ticks" -gt "$ITERATIONS" ]; then exit 0; fi
}
'

# run_media_loop <case> <probe results> <passes> [queue exit] [queue seconds]
run_media_loop() {
  setup_loop_root "media-$1"
  queue_seconds=${5:-0}
  # shellcheck disable=SC2086
  if env TEST_ROOT="$loop_root" PROBE_RESULTS="$2" ITERATIONS="$3" \
      QUEUE_EXIT="${4:-0}" QUEUE_SECONDS="$queue_seconds" \
      EXPECT_DELAY=$((60 - queue_seconds)) \
      "$test_sh" $test_sh_args -c "$media_prelude$(cat "$work/media-body.sh")" \
      > "$out" 2> "$err"; then
    status=0
  else
    status=$?
  fi
  probes=$(count "$calls" 'php:eval ')
  queue_runs=$(count_lines "$calls" "$queue_call")
  expect_eq "media $1: loop exit status" 0 "$status"
  expect_eq "media $1: probe on the first pass and every 15 passes" $((($3 + 14) / 15)) "$probes"
  expect_eq "media $1: exact probe source" "$probes" "$(count_lines "$calls" "php:eval $probe_source")"
}

expect_eq "probe source avoids exit()" 0 "$(printf '%s\n' "$probe_source" | grep -c -F 'exit(' || true)"

run_media_loop available available:0 2
expect_eq "media available: queue runs" 2 "$queue_runs"
expect_eq "media available: worker stdout reaches the log" 2 "$(count "$out" 'queue worker output')"
expect_eq "media available: worker stderr reaches the log" 2 "$(count "$err" 'queue worker error')"
expect_eq "media available: no probe noise" 00 "$(count "$out" probe)$(count "$err" probe)"
expect_eq "media available: no runner messages" 00 "$(count "$out" 'Media intake')$(count "$err" 'Media intake')"

run_media_loop cadence available:0 31
expect_eq "media cadence: probe positions" "1 17 33 " "$(grep -n -F 'php:eval ' "$calls" | cut -d: -f1 | tr '\n' ' ')"
expect_eq "media cadence: queue runs" 31 "$queue_runs"

for code in 1 255; do
  run_media_loop "probe-failure-$code" "abnormal:$code" 31
  expect_eq "media probe-failure-$code: no queue runs" 0 "$queue_runs"
  expect_eq "media probe-failure-$code: failure logged once" 1 "$(count "$err" "Media intake worker probe failed (exit $code)")"
  expect_eq "media probe-failure-$code: diagnostics logged once" 1 "$(count "$err" 'probe diagnostic stdout')"
  expect_eq "media probe-failure-$code: diagnostics stderr logged once" 1 "$(count "$err" 'probe diagnostic stderr')"
done

run_media_loop later-install 'missing:0 available:0' 17
expect_eq "media later-install: queue runs after the recheck" 2 "$queue_runs"
expect_eq "media later-install: missing logged once" 1 "$(count_lines "$out" 'Media intake worker not installed; next check in 15 minutes')"
expect_eq "media later-install: no probe failure" 0 "$(count "$err" 'probe failed')"

run_media_loop failed-reprobe 'available:0 abnormal:255 available:0' 31
expect_eq "media failed-reprobe: worker paused until recovery" 16 "$queue_runs"
expect_eq "media failed-reprobe: failure logged once" 1 "$(count "$err" 'probe failed')"

run_media_loop missing missing:0 31
expect_eq "media missing: worker stays paused" 0 "$queue_runs"
expect_eq "media missing: missing logged once" 1 "$(count "$out" 'not installed; next check in 15 minutes')"
expect_eq "media missing: no probe failure" 0 "$(count "$err" 'probe failed')"

run_media_loop marker-with-failed-exit available:1 3
expect_eq "media marker-with-failed-exit: not available" 0 "$queue_runs"
expect_eq "media marker-with-failed-exit: failure logged" 1 "$(count "$err" 'probe failed (exit 1)')"

run_media_loop echoed-source echo-source:0 3
expect_eq "media echoed-source: not available" 0 "$queue_runs"
expect_eq "media echoed-source: read as missing" 1 "$(count "$out" 'not installed')"
expect_eq "media echoed-source: no probe failure" 0 "$(count "$err" 'probe failed')"

for answer in missing-then-available available-then-missing; do
  run_media_loop "$answer" "$answer:0" 2
  expect_eq "media $answer: missing wins" 0 "$queue_runs"
  expect_eq "media $answer: read as missing" 1 "$(count "$out" 'not installed')"
done

run_media_loop no-marker no-marker:0 31
expect_eq "media no-marker: not available" 0 "$queue_runs"
expect_eq "media no-marker: probe failure" 1 "$(count "$err" 'probe failed (exit 0)')"
expect_eq "media no-marker: not read as missing" 0 "$(count "$out" 'not installed')"

run_media_loop missing-with-failed-exit missing:9 2
expect_eq "media missing-with-failed-exit: not available" 0 "$queue_runs"
expect_eq "media missing-with-failed-exit: probe failure" 1 "$(count "$err" 'probe failed (exit 9)')"
expect_eq "media missing-with-failed-exit: not read as missing" 0 "$(count "$out" 'not installed')"

run_media_loop each-once 'missing:0 abnormal:1 missing:0 abnormal:1' 46
expect_eq "media each-once: missing logged once" 1 "$(count "$out" 'not installed; next check in 15 minutes')"
expect_eq "media each-once: failure logged once" 1 "$(count "$err" 'probe failed (exit 1)')"

run_media_loop queue-failure available:0 2 9
expect_eq "media queue-failure: next pass still runs" 2 "$queue_runs"
expect_eq "media queue-failure: failure line with exit code" 2 \
  "$(count_lines "$err" 'Media intake queue run failed (exit 9); next attempt within a minute')"
expect_eq "media queue-failure: worker stderr reaches the log" 2 "$(count "$err" 'queue worker error')"

run_media_loop processing-time available:0 2 0 50
expect_eq "media processing-time: processing time is part of the minute" 2 "$queue_runs"

if [ "$failures" -ne 0 ]; then
  printf 'Runtime entrypoint tests: %s of %s checks failed (%s).\n' "$failures" "$checks" "$test_sh $test_sh_args" >&2
  exit 1
fi
printf 'Runtime entrypoint tests passed: %s checks (%s).\n' "$checks" "$test_sh $test_sh_args"
