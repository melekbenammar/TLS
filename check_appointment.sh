#!/bin/bash

# Configuration
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

# Fichiers temporaires
COOKIE_FILE="/tmp/tlscontact_cookies.txt"
HEADERS_FILE="/tmp/tlscontact_headers.txt"
RESPONSE_FILE="/tmp/tlscontact_response.html"
LOG_FILE="/tmp/appointment_checker.log"

# User-Agent pour éviter la détection
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"

    log "Envoi de l'email de notification..."

    # Utilisation de sendmail ou curl pour l'envoi d'email
    if command -v sendmail &> /dev/null; then
        echo -e "Subject: $subject\nFrom: $EMAIL_FROM\nTo: $EMAIL_TO\n\n$body" | sendmail -t
    else
        # Alternative avec curl et SMTP
        curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
             --ssl-reqd \
             --mail-from "$EMAIL_FROM" \
             --mail-rcpt "$EMAIL_TO" \
             --user "$SMTP_USER:$SMTP_PASSWORD" \
             -T <(echo -e "From: $EMAIL_FROM\nTo: $EMAIL_TO\nSubject: $subject\n\n$body") \
             2>&1 | tee -a "$LOG_FILE"
    fi
}

login() {
    log "Connexion au site TLS Contact..."

    # Première requête pour obtenir les cookies et tokens CSRF
    curl -s -L \
         -A "$USER_AGENT" \
         -c "$COOKIE_FILE" \
         -D "$HEADERS_FILE" \
         "$LOGIN_URL" > /dev/null

    sleep $((2 + RANDOM % 3))

    # Extraction du token CSRF si présent
    CSRF_TOKEN=$(grep -oP 'csrf[_-]?token["\s:=]+\K[a-zA-Z0-9_-]+' "$RESPONSE_FILE" 2>/dev/null | head -1)

    # Tentative de connexion
    curl -s -L \
         -A "$USER_AGENT" \
         -b "$COOKIE_FILE" \
         -c "$COOKIE_FILE" \
         -D "$HEADERS_FILE" \
         -H "Content-Type: application/x-www-form-urlencoded" \
         -H "Origin: https://visas-fr.tlscontact.com" \
         -H "Referer: $LOGIN_URL" \
         --data-urlencode "email=$USERNAME" \
         --data-urlencode "password=$PASSWORD" \
         --data-urlencode "csrf_token=$CSRF_TOKEN" \
         "$LOGIN_URL" -o "$RESPONSE_FILE"

    # Vérification de la connexion réussie
    if grep -q "logout\|dashboard\|appointment" "$RESPONSE_FILE" 2>/dev/null; then
        log "Connexion réussie"
        return 0
    else
        log "ERREUR: Échec de connexion"
        return 1
    fi
}

check_appointments() {
    log "Vérification des créneaux disponibles..."

    # Délai aléatoire pour simuler un comportement humain
    sleep $((2 + RANDOM % 4))

    # Requête pour vérifier les rendez-vous
    curl -s -L \
         -A "$USER_AGENT" \
         -b "$COOKIE_FILE" \
         -c "$COOKIE_FILE" \
         -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
         -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8" \
         -H "Referer: https://visas-fr.tlscontact.com/" \
         "$CHECK_URL" -o "$RESPONSE_FILE"

    # Vérification si la session a expiré
    if grep -q "login\|connexion\|sign.in" "$RESPONSE_FILE" 2>/dev/null; then
        log "Session expirée, reconnexion..."
        login
        return 2
    fi

    # Recherche de créneaux disponibles (adapter selon le HTML du site)
    if grep -qi "available\|disponible\|rendez-vous disponible\|créneau disponible\|book now\|réserver" "$RESPONSE_FILE" 2>/dev/null; then
        if ! grep -qi "aucun.*disponible\|no.*available\|complet" "$RESPONSE_FILE" 2>/dev/null; then
            log "CRÉNEAU TROUVÉ !"
            return 0
        fi
    fi

    log "Aucun créneau disponible pour le moment"
    return 1
}

main_loop() {
    log "=== Démarrage du script de surveillance ==="

    # Connexion initiale
    if ! login; then
        log "ERREUR CRITIQUE: Impossible de se connecter. Vérifiez vos identifiants."
        send_email "Erreur - Script Rendez-vous" "Impossible de se connecter au site TLS Contact. Vérifiez les identifiants."
        exit 1
    fi

    local check_count=0
    local last_login=$(date +%s)

    while true; do
        check_count=$((check_count + 1))
        log "--- Vérification #$check_count ---"

        # Reconnexion toutes les 2 heures pour maintenir la session
        current_time=$(date +%s)
        if [ $((current_time - last_login)) -gt 7200 ]; then
            log "Renouvellement de la session (2h écoulées)"
            login
            last_login=$(date +%s)
        fi

        result=$(check_appointments; echo $?)

        case $result in
            0)
                # Créneau trouvé !
                log "!!! ALERTE: Créneau de rendez-vous détecté !!!"
                send_email "🎯 RENDEZ-VOUS DISPONIBLE - TLS Contact" \
                           "Un créneau de rendez-vous est maintenant disponible !\n\nURL: $CHECK_URL\n\nConnectez-vous rapidement pour réserver.\n\nDate de détection: $(date '+%Y-%m-%d %H:%M:%S')"

                # Copie du fichier de réponse pour analyse
                cp "$RESPONSE_FILE" "/tmp/appointment_found_$(date +%Y%m%d_%H%M%S).html"

                # Notification sonore si le serveur a un terminal
                if [ -n "$DISPLAY" ] && command -v paplay &> /dev/null; then
                    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
                fi

                log "Pause de 30 minutes après détection..."
                sleep 1800
                ;;
            2)
                # Session expirée, déjà gérée
                ;;
            *)
                # Pas de créneau
                ;;
        esac

        # Attente de 5 minutes avec une petite variation aléatoire
        sleep_time=$((300 + RANDOM % 60))
        log "Prochaine vérification dans ${sleep_time}s..."
        sleep $sleep_time
    done
}

# Gestion des signaux pour arrêt propre
trap 'log "Arrêt du script..."; rm -f "$COOKIE_FILE" "$HEADERS_FILE" "$RESPONSE_FILE"; exit 0' SIGINT SIGTERM

# Lancement
main_loop
