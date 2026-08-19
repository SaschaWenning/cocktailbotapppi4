#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/etc/cocktailbot/paypal.env
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }

CURRENT_MODE=sandbox
CURRENT_ID=""
CURRENT_RETURN=""
CURRENT_CANCEL=""
if [[ -f "$ENV_FILE" ]]; then
  CURRENT_MODE="$(grep -E '^COCKTAILBOT_PAYPAL_MODE=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  CURRENT_ID="$(grep -E '^COCKTAILBOT_PAYPAL_CLIENT_ID=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  CURRENT_RETURN="$(grep -E '^COCKTAILBOT_PAYPAL_RETURN_URL=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  CURRENT_CANCEL="$(grep -E '^COCKTAILBOT_PAYPAL_CANCEL_URL=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
fi

read -r -p "PayPal Modus [sandbox/live] (${CURRENT_MODE:-sandbox}): " MODE
MODE="${MODE:-${CURRENT_MODE:-sandbox}}"
[[ "$MODE" == sandbox || "$MODE" == live ]] || { echo "Ungültiger Modus." >&2; exit 2; }

read -r -p "PayPal Client-ID${CURRENT_ID:+ [vorhanden]}: " CLIENT_ID
CLIENT_ID="${CLIENT_ID:-$CURRENT_ID}"
[[ -n "$CLIENT_ID" ]] || { echo "Client-ID darf nicht leer sein." >&2; exit 2; }

read -r -s -p "PayPal Client-Secret: " CLIENT_SECRET
echo
[[ -n "$CLIENT_SECRET" ]] || { echo "Client-Secret darf nicht leer sein." >&2; exit 2; }

read -r -p "Return-URL (leer = PayPal-Startseite)${CURRENT_RETURN:+ [$CURRENT_RETURN]}: " RETURN_URL
RETURN_URL="${RETURN_URL:-$CURRENT_RETURN}"
read -r -p "Cancel-URL (leer = Return-URL)${CURRENT_CANCEL:+ [$CURRENT_CANCEL]}: " CANCEL_URL
CANCEL_URL="${CANCEL_URL:-$CURRENT_CANCEL}"

for value in "$CLIENT_ID" "$CLIENT_SECRET" "$RETURN_URL" "$CANCEL_URL"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { echo "Zeilenumbrüche sind nicht erlaubt." >&2; exit 2; }
done

install -d -m 0755 /etc/cocktailbot
umask 077
cat > "$ENV_FILE" <<ENV
COCKTAILBOT_PAYPAL_MODE=$MODE
COCKTAILBOT_PAYPAL_CLIENT_ID=$CLIENT_ID
COCKTAILBOT_PAYPAL_CLIENT_SECRET=$CLIENT_SECRET
COCKTAILBOT_PAYMENT_DB=/var/lib/cocktailbot/payments.db
COCKTAILBOT_PAYPAL_BRAND_NAME=CocktailBot
COCKTAILBOT_PAYPAL_RETURN_URL=$RETURN_URL
COCKTAILBOT_PAYPAL_CANCEL_URL=$CANCEL_URL
COCKTAILBOT_PAYPAL_TIMEOUT_SECONDS=15
ENV
chmod 0600 "$ENV_FILE"

systemctl restart cocktailbot.service
sleep 2

echo
echo "Lokales Zahlungsbackend:"
curl -fsS http://127.0.0.1:8080/api/payment/status || true
echo
echo
echo "Teste PayPal OAuth-Zugang ..."
if curl -fsS -X POST http://127.0.0.1:8080/api/payment/test; then
  echo
  echo "PayPal-Verbindung erfolgreich."
else
  echo
  echo "PayPal-Test fehlgeschlagen. Prüfe: journalctl -u cocktailbot.service -n 100" >&2
  exit 1
fi
