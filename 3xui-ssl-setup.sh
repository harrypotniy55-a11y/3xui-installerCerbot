
#!/bin/bash
set -Eeuo pipefail

# ==========================================
# 3X-UI SSL CERTIFICATE INSTALLER
# Docker (get.docker.com) + Let's Encrypt
# + automatic renewal via cron
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

echo
echo "========================================"
echo "       3X-UI SSL CONFIGURATION"
echo "========================================"

# 1. Ask for panel domain and contact email
read -rp "Enter 3X-UI panel domain (example: panel.example.com): " DOMAIN
read -rp "Enter your valid email address: " EMAIL

DOMAIN="${DOMAIN//[[:space:]]/}"
EMAIL="${EMAIL//[[:space:]]/}"

if [[ -z "$DOMAIN" || ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || "$DOMAIN" != *.* ]]; then
    echo "ERROR: Invalid domain."
    exit 1
fi

if [[ ! "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    echo "ERROR: Invalid email address."
    exit 1
fi

echo
echo "Panel domain: $DOMAIN"
echo "Email: $EMAIL"

read -rp "Continue with these settings? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 1
fi

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
RENEW_SCRIPT="/usr/local/sbin/renew-3xui-cert.sh"
CONFIG_FILE="/etc/default/3xui-cert-renew"

# 2. Install curl if needed
if ! command -v curl >/dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update
    apt-get install -y curl
fi

# 3. Check/install Docker using the official Docker installer
echo
echo "Checking Docker installation..."

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed. Installing from get.docker.com..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable --now docker

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker Engine is not responding."
    exit 1
fi

echo "Docker is installed and running."

# 4. Prepare Certbot storage
mkdir -p /etc/letsencrypt /var/lib/letsencrypt

# 5. Initial certificate issuance (only if missing)
if [[ ! -s "$CERT" ]]; then
    echo
    echo "Certificate not found. Starting initial issuance..."

    (
        restart_services() {
            echo "Starting x-ui..."
            systemctl start x-ui || echo "WARNING: Failed to start x-ui"
            echo "Starting nginx..."
            systemctl start nginx || echo "WARNING: Failed to start nginx"
        }

        trap restart_services EXIT

        echo "Stopping nginx..."
        systemctl stop nginx

        echo "Stopping x-ui..."
        systemctl stop x-ui

        docker run --rm \
            -v /etc/letsencrypt:/etc/letsencrypt \
            -v /var/lib/letsencrypt:/var/lib/letsencrypt \
            --network host \
            certbot/certbot certonly --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN"

        if [[ ! -s "$CERT" ]]; then
            echo "ERROR: Certificate was not created."
            exit 1
        fi

        chmod -R 755 /etc/letsencrypt/live/
        chmod -R 755 /etc/letsencrypt/archive/
        chmod 644 "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        chmod 644 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

        echo "Certificate successfully issued."
    )
else
    echo "Certificate already exists. Skipping initial issuance."
fi

# 6. Save the selected domain and email for the renewal job
printf 'DOMAIN=%q\nEMAIL=%q\n' "$DOMAIN" "$EMAIL" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# 7. Create renewal script
cat > "$RENEW_SCRIPT" <<'RENEW_EOF'
#!/bin/bash
set -Eeuo pipefail

source /etc/default/3xui-cert-renew
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo "========================================"
echo "3X-UI Let's Encrypt certificate renewal"
echo "Date: $(date)"
echo "Domain: $DOMAIN"
echo "========================================"

# Ensure Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is missing. Installing official Docker package..."

    if ! command -v curl >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl
    fi

    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable --now docker

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker Engine is not responding."
    exit 1
fi

if [[ ! -s "$CERT" ]]; then
    echo "ERROR: Certificate not found: $CERT"
    exit 1
fi

EXPIRY=$(date -d "$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)" +%s)
NOW=$(date +%s)
DAYS_LEFT=$(( (EXPIRY - NOW) / 86400 ))

echo "Days until expiration: $DAYS_LEFT"

if (( DAYS_LEFT > 7 )); then
    echo "Renewal not required. More than 7 days remaining."
    exit 0
fi

restart_services() {
    echo "Starting x-ui..."
    systemctl start x-ui || echo "WARNING: Failed to start x-ui"
    echo "Starting nginx..."
    systemctl start nginx || echo "WARNING: Failed to start nginx"
}

trap restart_services EXIT

echo "Stopping nginx..."
systemctl stop nginx

echo "Stopping x-ui..."
systemctl stop x-ui

docker run --rm \
    -v /etc/letsencrypt:/etc/letsencrypt \
    -v /var/lib/letsencrypt:/var/lib/letsencrypt \
    --network host \
    certbot/certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --force-renewal \
    -d "$DOMAIN"

if [[ ! -s "$CERT" ]]; then
    echo "ERROR: Certificate not found after renewal."
    exit 1
fi

chmod -R 755 /etc/letsencrypt/live/
chmod -R 755 /etc/letsencrypt/archive/
chmod 644 "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
chmod 644 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo "Certificate successfully renewed."
RENEW_EOF

chmod 700 "$RENEW_SCRIPT"

# 8. Schedule daily check at 03:17
cat > /etc/cron.d/3xui-cert-renew <<'CRON_EOF'
17 3 * * * root /usr/local/sbin/renew-3xui-cert.sh >> /var/log/3xui-cert-renew.log 2>&1
CRON_EOF

chmod 644 /etc/cron.d/3xui-cert-renew

systemctl enable --now cron

# 9. Final installation summary
echo
echo "================================================"
echo "          SSL CONFIGURATION COMPLETED"
echo "================================================"
echo
echo "PANEL INFORMATION"
echo "------------------------------------------------"
echo "Panel domain:       $DOMAIN"
echo "Email:              $EMAIL"
echo
echo "SSL CERTIFICATE"
echo "------------------------------------------------"
echo "Certificate:        /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Private key:        /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo
echo "AUTOMATIC RENEWAL"
echo "------------------------------------------------"
echo "Renewal script:     $RENEW_SCRIPT"
echo "Configuration:      $CONFIG_FILE"
echo "Schedule:           Daily at 03:17"
echo "Cron log:           /var/log/3xui-cert-renew.log"
echo
echo "DOCKER"
echo "------------------------------------------------"
echo "Docker status:      $(systemctl is-active docker)"
echo
echo "================================================"
echo "       INSTALLATION FINISHED SUCCESSFULLY"
echo "================================================"
