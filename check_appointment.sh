#!/bin/bash

###############################################
#                CONFIGURATION                #
###############################################

USERNAME="your_email@example.com"
PASSWORD="your_password"

CHECK_URL="https://visas-fr.tlscontact.com/fr-fr/23419561/workflow/appointment-booking?location=tnTUN2fr&month=12-2025"
LOGIN_URL="https://visas-fr.tlscontact.com/login"

EMAIL_TO="your_notification_email@example.com"
EMAIL_FROM="noreply@yourdomain.com"
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_smtp_user@gmail.com"
SMTP_PASSWORD="your_smtp_password"

###############################################
#                TEMP FILES                   #
###############################################

COOKIE_FILE="/tmp/tlscontact_cookies.txt"
HEADERS_FILE="/tmp/tlscontact_headers.txt"
RESPONSE_FILE="/tmp/tlscontact_response.html"
LOG_FILE="/tmp/appointment_checker.log"

USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

###############################################
#                FONCTIONS                    #
###############################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"

    log "Envoi de l'email: $subject"

    if command -v sendmail &>/dev/null; then
        echo -e "Subject: $subject\nFrom: $EMAIL_FROM\nTo: $EMAIL_TO\n\n$body" | sendmail -t
    else
        curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$EMAIL_FROM" \
            --mail-rcpt "$EMAIL_TO" \
            --user "$SMTP_USER:$SMTP_PASSWORD" \
            -T <(echo -e "From: $EMAIL_FROM\nTo: $EMAIL_TO\nSubject: $subject\n\n$body") \
            2>&1 | tee -a "$LOG_FILE"
    fi
}

###############################################
#     🧪 CONTRÔLE D’EXPIRATION DES COOKIES    #
###############################################

check_cookie_expiration() {
    if [ ! -f "$COOKIE_FILE" ]; then
        log "Aucun cookie présent → pas de contrôle."
        return 1
    fi

    log "Vérification de l’expiration du cookie…"

    # recherche expiration dans fichier cookie Netscape
    expiry=$(awk '{if ($1 !~ /^#/ && $5 ~ /^[0-9]+$/) print $5}' "$COOKIE_FILE" | sort -nr | head -1)

    if [[ -z "$expiry" ]]; then
        log "Format des cookies invalide → probable expiration."
        send_email "TLSContact – Cookies expirés" "Les cookies TLSContact sont invalides ou expirés. Une reconnexion est nécessaire."
        return 1
    fi

    now=$(date +%s)

    if (( expiry <= now )); then
        log "Cookies EXPIRÉS."
        send_email "TLSContact – Cookies expirés" "Les cookies TLSContact ont expiré. Le script va tenter une reconnexion."
        return 1
    fi

    log "Cookies valides (expiration: $(date -d @$expiry))"
    return 0
}

###############################################
#                LOGIN TLS                    #
###############################################

login() {
    log "Connexion à TLS Contact…"

    # Step 1 : Page login
    curl -s -L \
        -A "$USER_AGENT" \
        -c "$COOKIE_FILE" \
        "$LOGIN_URL" \
        -o "$RESPONSE_FILE"

    sleep 2

    # Extraction du token CSRF
    csrf_token=$(grep -oP '(?:_token|csrf)["\s:=]*value=["\s]*\K[a-zA-Z0-9_/+\-=]+' "$RESPONSE_FILE" | head -1)

    log "Token CSRF: ${csrf_token:0:10}..."

    # Step 2 : Login POST
    curl -s -L \
        -A "$USER_AGENT" \
        -b "$COOKIE_FILE" \
        -c "$COOKIE_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "email=$USERNAME" \
        --data-urlencode "password=$PASSWORD" \
        --data-urlencode "_token=$csrf_token" \
        "$LOGIN_URL" -o "$RESPONSE_FILE"

    sleep 2

    if grep -qi "logout\|dashboard\|mes rendez-vous" "$RESPONSE_FILE"; then
        log "Connexion réussie."
        return 0
    fi

    log "Erreur de connexion."
    return 1
}

###############################################
#     CHECK DES CRENEAUX                      #
###############################################

check_appointments() {
    log "Vérification des rendez-vous…"

    curl -s -L \
        -A "$USER_AGENT" \
        -b "$COOKIE_FILE" \
        -c "$COOKIE_FILE" \
        "$CHECK_URL" -o "$RESPONSE_FILE"

    # Session expirée ?
    if grep -qi "login\|connexion" "$RESPONSE_FILE"; then
        log "Session expirée."
        return 2
    fi

    # Slot détecté ?
    if grep -qi "réserver\|slot\|available" "$RESPONSE_FILE"; then
        if ! grep -qi "no slot\|aucun\|complet" "$RESPONSE_FILE"; then
            log "Créneau disponible !"
            return 0
        fi
    fi

    log "Pas de créneau."
    return 1
}

###############################################
#                MAIN LOOP                    #
###############################################

main_loop() {

    log "=== Démarrage du script TLS Contact ==="

    # 🔥 Contrôle cookies AVANT login
    if ! check_cookie_expiration; then
        log "Cookies invalides → tentative de login."
        login || {
            send_email "TLSContact – Erreur login" "La connexion TLSContact a échoué."
            exit 1
        }
    fi

    last_login=$(date +%s)

    while true; do
        log "--- Nouvelle vérification ---"

        now=$(date +%s)
        if (( now - last_login > 7200 )); then
            log "Session >2h → renouvèlement…"
            login
            last_login=$(date +%s)
        fi

        result=$(check_appointments; echo $?)

        case $result in
            0)
                send_email "⚠️ RDV DISPONIBLE – TLS CONTACT" \
                "Un créneau est disponible !\n$CHECK_URL\nDétection: $(date)"
                cp "$RESPONSE_FILE" "/tmp/appointment_found_$(date +%Y%m%d_%H%M%S).html"
                log "Pause 30 minutes après détection."
                sleep 1800
                ;;
            2)
                log "Session expirée → login."
                login
                ;;
        esac

        sleep $((300 + RANDOM % 60))
    done
}

trap 'log "Arrêt du script."; rm -f "$COOKIE_FILE" "$HEADERS_FILE" "$RESPONSE_FILE"; exit 0' SIGINT SIGTERM

main_loop
