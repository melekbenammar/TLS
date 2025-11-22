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
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

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
    log "Tentative de connexion au site TLS Contact..."

    sleep $((1 + RANDOM % 2))

    # Première requête pour passer Cloudflare et obtenir les cookies
    log "Étape 1: Accès à la page de connexion..."

    curl -s -L \
         -A "$USER_AGENT" \
         -c "$COOKIE_FILE" \
         -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" \
         -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8,en-US;q=0.7" \
         -H "Accept-Encoding: gzip, deflate, br" \
         -H "DNT: 1" \
         -H "Connection: keep-alive" \
         -H "Upgrade-Insecure-Requests: 1" \
         -H "Sec-Fetch-Dest: document" \
         -H "Sec-Fetch-Mode: navigate" \
         -H "Sec-Fetch-Site: none" \
         -H "Cache-Control: max-age=0" \
         "$LOGIN_URL" -o "$RESPONSE_FILE" 2>&1

    sleep $((2 + RANDOM % 3))

    # Extraction du token CSRF ou autres paramètres
    local csrf_token=""
    if grep -q "_token\|csrf\|token" "$RESPONSE_FILE"; then
        csrf_token=$(grep -oP '(?:_token|csrf)["\s:=]*value=["\s]*\K[a-zA-Z0-9_/+\-=]+' "$RESPONSE_FILE" 2>/dev/null | head -1)
        if [ -n "$csrf_token" ]; then
            log "Token CSRF trouvé: ${csrf_token:0:20}..."
        fi
    fi

    # Tentative de connexion
    log "Étape 2: Envoi des identifiants..."

    if [ -n "$csrf_token" ]; then
        curl -s -L \
             -A "$USER_AGENT" \
             -b "$COOKIE_FILE" \
             -c "$COOKIE_FILE" \
             -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" \
             -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8,en-US;q=0.7" \
             -H "Content-Type: application/x-www-form-urlencoded" \
             -H "Origin: https://visas-fr.tlscontact.com" \
             -H "Referer: $LOGIN_URL" \
             -H "Cache-Control: max-age=0" \
             -H "Sec-Fetch-Dest: document" \
             -H "Sec-Fetch-Mode: navigate" \
             -H "Sec-Fetch-Site: same-origin" \
             --data-urlencode "email=$USERNAME" \
             --data-urlencode "password=$PASSWORD" \
             --data-urlencode "_token=$csrf_token" \
             "$LOGIN_URL" -o "$RESPONSE_FILE" 2>&1
    else
        curl -s -L \
             -A "$USER_AGENT" \
             -b "$COOKIE_FILE" \
             -c "$COOKIE_FILE" \
             -H "Content-Type: application/x-www-form-urlencoded" \
             -H "Origin: https://visas-fr.tlscontact.com" \
             -H "Referer: $LOGIN_URL" \
             --data-urlencode "email=$USERNAME" \
             --data-urlencode "password=$PASSWORD" \
             "$LOGIN_URL" -o "$RESPONSE_FILE" 2>&1
    fi

    sleep 2

    # Vérification de la connexion réussie
    if grep -qi "logout\|mes rendez-vous\|my appointments\|dashboard\|bienvenue" "$RESPONSE_FILE" 2>/dev/null; then
        log "Connexion réussie !"
        return 0
    elif grep -qi "recaptcha\|challenge\|verify" "$RESPONSE_FILE" 2>/dev/null; then
        log "ERREUR: reCAPTCHA détecté. Le site nécessite une vérification manuelle."
        log "Solution: Connectez-vous manuellement une fois, puis relancez le script."
        return 1
    elif grep -qi "email\|password\|incorrect\|invalide" "$RESPONSE_FILE" 2>/dev/null; then
        log "ERREUR: Email ou mot de passe incorrect"
        return 1
    else
        log "ERREUR: Impossible de se connecter (vérifiez la réponse)"
        log "Extrait de la réponse: $(head -c 200 "$RESPONSE_FILE")"
        return 1
    fi
}

check_appointments() {
    log "Vérification des créneaux disponibles..."

    sleep $((1 + RANDOM % 3))

    # Requête pour vérifier les rendez-vous
    curl -s -L \
         -A "$USER_AGENT" \
         -b "$COOKIE_FILE" \
         -c "$COOKIE_FILE" \
         -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" \
         -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8,en-US;q=0.7" \
         -H "Accept-Encoding: gzip, deflate, br" \
         -H "Referer: https://visas-fr.tlscontact.com/" \
         -H "DNT: 1" \
         -H "Connection: keep-alive" \
         -H "Upgrade-Insecure-Requests: 1" \
         "$CHECK_URL" -o "$RESPONSE_FILE" 2>&1

    # Vérification si la session a expiré
    if grep -qi "login\|connexion\|sign.in\|authentification" "$RESPONSE_FILE" 2>/dev/null; then
        log "Session expirée, reconnexion..."
        login
        return 2
    fi

    # Recherche de créneaux disponibles
    if grep -qi "disponible\|available.*slot\|book.*appointment\|réserver" "$RESPONSE_FILE" 2>/dev/null; then
        if ! grep -qi "aucun.*disponible\|no.*slot\|fully booked\|complet" "$RESPONSE_FILE" 2>/dev/null; then
            log "CRÉNEAU TROUVÉ !"
            return 0
        fi
    fi

    log "Aucun créneau disponible pour le moment"
    return 1
}

main_loop() {
    log "=== Démarrage du script de surveillance TLS Contact ==="
    log "Vérification toutes les 5 minutes"

    # Connexion initiale
    if ! login; then
        log "ERREUR CRITIQUE: Impossible de se connecter. Vérifiez vos identifiants."
        send_email "Erreur - Script Rendez-vous" "Impossible de se connecter au site TLS Contact.\n\nVérifiez:\n1. Les identifiants\n2. Pas de reCAPTCHA bloquant\n3. La connexion manuelle fonctionne"
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
                send_email "RENDEZ-VOUS DISPONIBLE - TLS Contact" \
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
