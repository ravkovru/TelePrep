#!/usr/bin/env bash
set -Eeuo pipefail

HOST="my.telegram.org"
PORT="443"
HOSTS_FILE="/etc/hosts"
TIMEOUT="15"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
open_private_safari() {
  command -v osascript >/dev/null || return 0
  open -a Safari >/dev/null 2>&1 || true
  osascript -e 'tell application "Safari" to activate' \
    -e 'delay 1' \
    -e 'tell application "System Events" to keystroke "n" using {command down, shift down}' \
    -e 'delay 1' \
    -e 'tell application "Safari" to set URL of front document to "https://my.telegram.org"' \
    >/dev/null 2>&1 || printf 'Предупреждение: не удалось открыть приватное окно Safari.\n' >&2
}
cleanup() {
  if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
    sudo cp "$BACKUP_FILE" "$HOSTS_FILE"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE=""
    printf '\nВременная запись удалена, hosts восстановлен.\n'
  fi
}
trap cleanup EXIT INT TERM

command -v curl >/dev/null || die "не найден curl"
command -v sudo >/dev/null || die "не найден sudo"
if [[ -n "${PROXY_URL:-}" ]]; then
  CURL_PROXY=(--proxy "$PROXY_URL")
  printf 'Используется временный прокси: %s\n' "$PROXY_URL"
else
  CURL_PROXY=()
fi

printf '1. Подключите VPN к Казахстану.\n'
printf '   Выполняю nslookup %s...\n' "$HOST"
NSLOOKUP_OUTPUT="$(nslookup "$HOST" 2>&1 || true)"
printf '%s\n' "$NSLOOKUP_OUTPUT"
DNS_IPS=( $(printf '%s\n' "$NSLOOKUP_OUTPUT" | awk '/^Address: / {print $2}' | awk '/^[0-9]+(\.[0-9]+){3}$/') )
[[ ${#DNS_IPS[@]} -gt 0 ]] || die "nslookup не вернул IP для $HOST"
read -r -p 'После включения VPN нажмите Enter для подтверждения... ' _

if [[ "${TEST_MODE:-0}" == "1" ]]; then
  COUNTRY="KZ"
  VPN_IP="198.51.100.10"
  printf '   ТЕСТОВЫЙ РЕЖИМ: используются условные данные, реальный IP не проверяется.\n'
else
  COUNTRY="$(curl "${CURL_PROXY[@]}" -fsS --connect-timeout 5 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n' || true)"
  VPN_IP="$(curl "${CURL_PROXY[@]}" -fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
fi
printf '   Внешний IP: %s\n' "${VPN_IP:-не определён}"
printf '   Страна IP: %s\n' "${COUNTRY:-не определена}"
[[ "$COUNTRY" == "KZ" ]] || die "VPN не определён как Казахстан (получено: ${COUNTRY:-неизвестно}). Подключите VPN к Казахстану и запустите скрипт снова."
printf '   Казахстан подтверждён. Продолжаю.\n'
if [[ "${TEST_MODE:-0}" == "1" ]]; then
  printf 'Тест пройден: после подтверждения KZ скрипт продолжил бы сетевую проверку.\n'
  exit 0
fi

printf '2. Поиск IP %s...\n' "$HOST"
if [[ -n "${TELEGRAM_IP:-}" ]]; then
  IPS=("$TELEGRAM_IP")
else
  IPS=( "${DNS_IPS[@]}" )
fi
[[ ${#IPS[@]} -gt 0 ]] || die "IP не найден. Укажите его вручную: TELEGRAM_IP=... $0"

SELECTED=""
for ip in "${IPS[@]}"; do
  printf '   Проверяю %s...\n' "$ip"
  DIAG_FILE="$(mktemp -t telegram-curl-diag.XXXXXX)"
  code=$(curl "${CURL_PROXY[@]}" -sv -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 -m "$TIMEOUT" \
    --resolve "$HOST:$PORT:$ip" "https://$HOST" 2>"$DIAG_FILE" || true)
  if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
    protocol=$(awk '/^< HTTP\// {gsub("< ", ""); print $1; exit}' "$DIAG_FILE" || true)
    status_line=$(awk '/^< HTTP\// {gsub("< ", ""); print; exit}' "$DIAG_FILE" || true)
    printf '   Успех: %s\n' "${status_line:-HTTP $code}"
    SELECTED="$ip"
    rm -f "$DIAG_FILE"
    break
  fi
  if grep -Eqi 'Failed to connect|Could not connect|Connection timed out|Operation timed out' "$DIAG_FILE"; then
    printf '   Failed to connect / Connection timed out — hosts не поможет.\n'
  elif grep -Eqi 'Connection reset|SSL|schannel|TLS' "$DIAG_FILE"; then
    printf '   Connection reset / SSL/TLS — вероятна блокировка DPI, hosts не поможет.\n'
  elif grep -Eqi 'Could not resolve host|Name or service not known' "$DIAG_FILE"; then
    printf '   Не удалось разрешить имя хоста.\n'
  else
    printf '   Нет подходящего ответа (HTTP ${code:-ошибка}).\n'
  fi
  rm -f "$DIAG_FILE"
done
[[ -n "$SELECTED" ]] || die "сайт недоступен. Проверьте VPN, DPI и IP; hosts не поможет при блокировке трафика."

printf '3. Временная настройка hosts: %s %s\n' "$SELECTED" "$HOST"
BACKUP_FILE="$(mktemp -t telegram-hosts-backup.XXXXXX)"
sudo cp "$HOSTS_FILE" "$BACKUP_FILE"
if sudo awk -v host="$HOST" '$2 == host { found=1 } END { exit found ? 0 : 1 }' "$HOSTS_FILE"; then
  sudo sed -i '' "/[[:space:]]$HOST([[:space:]]|$)/d" "$HOSTS_FILE"
fi
printf '%s %s\n' "$SELECTED" "$HOST" | sudo tee -a "$HOSTS_FILE" >/dev/null
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

printf '\nГотово. Открываю страницу Telegram.\n'
open_private_safari
printf '%s\n' \
  'В браузере войдите по номеру, введите код Telegram и создайте приложение.' \
  'Сохраните api_id и api_hash в менеджере секретов или .env, не публикуйте их.' \
  'После завершения нажмите Ctrl+C в этом окне: hosts будет восстановлен автоматически.'
read -r -p 'Нажмите Enter после получения ключей для восстановления hosts... ' _
cleanup

