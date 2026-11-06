#!/bin/sh
set -eu

APP_USER=app
APP_GROUP=app
PUBLIC_FILES_DIR=/app/data/web/sites/default/files
PRIVATE_FILES_DIR=/app/data/private
DRUPAL_TMP_DIR=/tmp/drupal
SERVICES_FILE=/app/data/web/sites/default/runtime.services.yml

run_as_app() {
  if [ "$(id -u)" = "0" ]; then
    su-exec "$APP_USER" "$@"
  else
    "$@"
  fi
}

ensure_writable_dir() {
  directory="$1"
  mkdir -p "$directory"
  if [ "$(id -u)" = "0" ]; then
    chown "$APP_USER:$APP_GROUP" "$directory"
    chmod ug+rwx "$directory"
  fi
}

reject_multiline() {
  name="$1"
  value="$2"
  carriage_return="$(printf '\r')"
  case "$value" in
    *'
'*|*"$carriage_return"*)
      echo "ERROR: $name must not contain line breaks" >&2
      exit 1
      ;;
  esac
}

ensure_writable_dir "$PUBLIC_FILES_DIR"
ensure_writable_dir "$PUBLIC_FILES_DIR/styles"
ensure_writable_dir "$PRIVATE_FILES_DIR"
ensure_writable_dir "$DRUPAL_TMP_DIR"

cookie_domain="${COOKIE_DOMAIN:-}"
smtp_host="${SMTP_HOST:-}"
smtp_port="${SMTP_PORT:-}"
smtp_from="${SMTP_FROM:-}"
smtp_user="${SMTP_USER:-}"
smtp_password="${SMTP_PASSWORD:-}"
hash_salt="${DRUPAL_HASH_SALT:-}"

reject_multiline COOKIE_DOMAIN "$cookie_domain"
reject_multiline SMTP_HOST "$smtp_host"
reject_multiline SMTP_PORT "$smtp_port"
reject_multiline SMTP_FROM "$smtp_from"
reject_multiline SMTP_USER "$smtp_user"
reject_multiline SMTP_PASSWORD "$smtp_password"
reject_multiline DRUPAL_HASH_SALT "$hash_salt"

if [ "${1:-}" = "php-fpm" ] && [ "${#hash_salt}" -lt 32 ]; then
  echo "ERROR: DRUPAL_HASH_SALT must contain at least 32 characters" >&2
  exit 1
fi

if [ -n "$cookie_domain" ]; then
  if ! printf '%s' "$cookie_domain" | grep -qE '^\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$'; then
    echo "ERROR: COOKIE_DOMAIN must use the form .example.org" >&2
    exit 1
  fi
  {
    printf '%s\n' 'parameters:'
    printf '%s\n' '  session.storage.options:'
    printf '%s\n' '    gc_probability: 1'
    printf '%s\n' '    gc_divisor: 100'
    printf '%s\n' '    gc_maxlifetime: 200000'
    printf '%s\n' '    cookie_lifetime: 2000000'
    printf "    cookie_domain: '%s'\n" "$cookie_domain"
  } > "$SERVICES_FILE"
else
  rm -f "$SERVICES_FILE"
fi

msmtp_host="${smtp_host:-mailpit}"
msmtp_port="${smtp_port:-1025}"
msmtp_from="${smtp_from:-noreply@example.invalid}"
if [ "${MARKASPOT_MAIL_MODE:-}" != "production" ]; then
  msmtp_host=mailpit
  msmtp_port=1025
fi

rm -f /tmp/msmtprc
{
  printf '%s\n' 'defaults'
  printf '%s\n' 'logfile /tmp/msmtp.log'
  printf '%s\n' 'account default'
  printf 'host %s\n' "$msmtp_host"
  printf 'port %s\n' "$msmtp_port"
  printf 'from %s\n' "$msmtp_from"
  if [ "${MARKASPOT_MAIL_MODE:-}" = "production" ] && [ -n "$smtp_user" ] && [ -n "$smtp_password" ]; then
    printf '%s\n' 'tls on' 'tls_starttls on' 'auth on'
    printf 'user %s\n' "$smtp_user"
    printf 'password %s\n' "$smtp_password"
  else
    printf '%s\n' 'tls off' 'auth off'
  fi
} > /tmp/msmtprc
chmod 0600 /tmp/msmtprc
if [ "$(id -u)" = "0" ]; then
  chown "$APP_USER:$APP_GROUP" /tmp/msmtprc
fi

cron_enabled="${MARKASPOT_CRON_ENABLED:-false}"
case "$cron_enabled" in
  true|false) ;;
  *)
    echo "ERROR: MARKASPOT_CRON_ENABLED must be true or false" >&2
    exit 1
    ;;
esac

if [ "$cron_enabled" = "true" ]; then
  cron_interval="${MARKASPOT_CRON_INTERVAL:-900}"
  case "$cron_interval" in
    ''|*[!0-9]*)
      echo "ERROR: MARKASPOT_CRON_INTERVAL must be an integer from 60 to 86400" >&2
      exit 1
      ;;
  esac
  if [ "${#cron_interval}" -gt 5 ] || [ "$cron_interval" -lt 60 ] || [ "$cron_interval" -gt 86400 ]; then
    echo "ERROR: MARKASPOT_CRON_INTERVAL must be an integer from 60 to 86400" >&2
    exit 1
  fi
fi

# The background loops belong to the long-lived PHP-FPM container only. One-off
# containers (drush deploy, updatedb, migrations) share its environment and
# must never run cron or queue workers next to the command they were started
# for. The loops inherit the entrypoint's stdout and stderr, which remain the
# container log after the exec below. Writing to /proc/1/fd/1 would not work:
# PID 1 runs as root and the loops run as the app user.
if [ "$cron_enabled" = "true" ] && [ "${1:-}" = "php-fpm" ]; then
  # A failed run is named with its exit code instead of being swallowed, so a
  # stale cron shows up in the container log. Keep the "Drupal cron failed"
  # prefix stable: log monitoring matches on it.
  # Expand loop variables in the child shell, not in the entrypoint shell.
  # shellcheck disable=SC2016
  run_as_app env MARKASPOT_CRON_INTERVAL="$cron_interval" sh -lc '
    while true; do
      sleep "$MARKASPOT_CRON_INTERVAL"
      cron_exit=0
      (cd /app/data && ./vendor/bin/drush cron) || cron_exit=$?
      if [ "$cron_exit" -ne 0 ]; then
        printf "Drupal cron failed (exit %s); next attempt in %s seconds\n" "$cron_exit" "$MARKASPOT_CRON_INTERVAL" >&2
      fi
    done
  ' &

  # Screen imported images (GeoReport media_url, inbound mail) within about a
  # minute instead of waiting for the next cron run. Profiles without the
  # markaspot_media_intake queue worker keep the runner paused: it probes on
  # the first pass and every 15 passes, so a later module installation needs
  # no container restart. The lease time of 900 seconds keeps a claimed item
  # away from Drupal cron while this runner processes it.
  # shellcheck disable=SC2016
  run_as_app sh -lc '
    probe_tick=0
    worker_available=false
    probe_failure_logged=false
    worker_missing_logged=false
    sleep 60
    while true; do
      started=$(date +%s)
      if [ "$probe_tick" -eq 0 ]; then
        # Drush 13 reports any exit() inside php:eval as "terminated
        # abnormally" with exit 1, so the probe answers on stdout instead.
        # Available means exit 0 AND the marker; anything else keeps the
        # worker paused.
        probe_exit=0
        probe_output=$(cd /app/data && ./vendor/bin/drush php:eval "echo \\Drupal::service(\"plugin.manager.queue_worker\")->hasDefinition(\"markaspot_media_intake\") ? \"media-intake-worker=available\" : \"media-intake-worker=missing\";" 2>&1) || probe_exit=$?
        probe_available=false
        probe_missing=false
        if [ "$probe_exit" -eq 0 ]; then
          # The eval source names both markers; missing wins so an echoed
          # source can never read as available.
          case "$probe_output" in
            *media-intake-worker=missing*) probe_missing=true ;;
            *media-intake-worker=available*) probe_available=true ;;
          esac
        fi
        if [ "$probe_available" = true ]; then
          worker_available=true
        else
          worker_available=false
          if [ "$probe_missing" = true ]; then
            if [ "$worker_missing_logged" = false ]; then
              printf "Media intake worker not installed; next check in 15 minutes\n"
              worker_missing_logged=true
            fi
          elif [ "$probe_failure_logged" = false ]; then
            printf "Media intake worker probe failed (exit %s): %s\n" "$probe_exit" "$probe_output" >&2
            probe_failure_logged=true
          fi
        fi
      fi
      probe_tick=$(((probe_tick + 1) % 15))
      if [ "$worker_available" = true ]; then
        queue_exit=0
        (cd /app/data && ./vendor/bin/drush queue:run markaspot_media_intake --time-limit=50 --lease-time=900) || queue_exit=$?
        if [ "$queue_exit" -ne 0 ]; then
          printf "Media intake queue run failed (exit %s); next attempt within a minute\n" "$queue_exit" >&2
        fi
      fi
      # Include processing time in the interval; a slow item must not add a
      # further full minute before the next attempt.
      delay=$((60 - ($(date +%s) - started)))
      if [ "$delay" -gt 0 ]; then
        sleep "$delay"
      fi
    done
  ' &
fi

if [ "$(id -u)" = "0" ] && [ "${1:-}" != "php-fpm" ]; then
  exec su-exec "$APP_USER" "$@"
fi

exec "$@"
