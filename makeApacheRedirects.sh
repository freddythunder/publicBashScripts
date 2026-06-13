#!/usr/bin/env bash

set -euo pipefail

echo "Howdy! Welcome to my Apache2 Vhost tool!"
echo "This script will (and is safe to re-run if a step fails):"
echo "1. Ask for domain name and document root"
echo "2. Create the document root if needed"
echo "3. On first setup, create a temporary HTTP vhost for the ACME challenge"
echo "4. Enable needed Apache modules"
echo "5. Run/renew certbot covering BOTH example.com and www.example.com"
echo "6. Write the final config: example.com:80 and example.com:443 both"
echo "   redirect to https://www.example.com (the canonical host)"
echo "7. Test and reload Apache"
echo "------------------------------------------------------------"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
WEB_BASE="/var/www/html"
APACHE_LOG_DIR="/var/log/apache2"

confirm() {
    local prompt="${1:-Continue?}"
    local answer
    read -rp "$prompt [Y/n]: " answer
    answer="${answer:-Y}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_root_tools() {
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: sudo is required."
        exit 1
    fi
    if ! command -v apache2ctl >/dev/null 2>&1; then
        echo "Error: apache2ctl not found."
        exit 1
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        echo "Error: certbot not found."
        exit 1
    fi
}

normalize_domain() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##' | sed 's#/$##'
}

build_domain_vars() {
    # Given any form of the domain (example.com or www.example.com), figure out:
    #   BASE_DOMAIN : the bare/apex domain          (example.com)
    #   CANONICAL   : the host we actually serve     (www.example.com for www pairs)
    #   CERT_NAME   : stable certbot lineage name + live/ dir name
    #   FINALDOMAIN : stable name for the .conf file and log files
    #   IS_WWW_PAIR : "yes" when we manage both apex + www, "no" for a lone host
    local input_domain="$1"
    local first_label dotcount
    first_label=$(cut -d. -f1 <<< "$input_domain")
    dotcount=$(grep -o '\.' <<< "$input_domain" | wc -l | tr -d ' ')

    if [[ "$first_label" == "www" ]]; then
        # www.example.com  ->  apex is example.com
        BASE_DOMAIN="${input_domain#www.}"
        IS_WWW_PAIR="yes"
    elif [[ "$dotcount" -eq 1 ]]; then
        # example.com  ->  treat as an apex with a www sibling
        BASE_DOMAIN="$input_domain"
        IS_WWW_PAIR="yes"
    else
        # sub.example.com (not www)  ->  manage just this single host
        BASE_DOMAIN="$input_domain"
        IS_WWW_PAIR="no"
    fi

    if [[ "$IS_WWW_PAIR" == "yes" ]]; then
        CANONICAL="www.$BASE_DOMAIN"
    else
        CANONICAL="$BASE_DOMAIN"
    fi

    CERT_NAME="$BASE_DOMAIN"
    FINALDOMAIN="$BASE_DOMAIN"
}

write_temp_http_vhost() {
    local vhost_path="$1"
    local canonical="$2"
    local alt="$3"
    local docroot="$4"

    sudo tee "$vhost_path" > /dev/null <<EOF
# Temporary HTTP vhost (managed by makeApacheRedirects.sh) - used so certbot
# can satisfy the HTTP-01 challenge for every name before the SSL config exists.
<VirtualHost *:80>
    ServerName $canonical
$( [[ -n "$alt" ]] && echo "    ServerAlias $alt" )
    DocumentRoot $docroot

    <Directory $docroot>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/$FINALDOMAIN.error.log
    CustomLog ${APACHE_LOG_DIR}/$FINALDOMAIN.access.log combined
</VirtualHost>
EOF
}

write_final_vhost() {
    local vhost_path="$1"
    local canonical="$2"
    local base="$3"
    local docroot="$4"
    local cert_name="$5"
    local is_pair="$6"

    # For a www pair we also stand up an apex :443 vhost so that direct HTTPS
    # hits to https://example.com terminate TLS with the (now apex-covering)
    # certificate and 301 over to the canonical https://www.example.com host,
    # instead of falling through to the wrong/default SSL vhost.
    local alias_line=""
    local apex_https_block=""
    if [[ "$is_pair" == "yes" ]]; then
        alias_line="    ServerAlias $base
"
        apex_https_block="# Apex HTTPS -> canonical HTTPS (TLS handshake succeeds because the cert
# covers $base as well, then we redirect).
<VirtualHost *:443>
    ServerName $base

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$cert_name/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$cert_name/privkey.pem
    Include /etc/letsencrypt/options-ssl-apache.conf

    RewriteEngine On
    RewriteRule ^ https://$canonical%{REQUEST_URI} [R=301,L]
</VirtualHost>

"
    fi

    sudo tee "$vhost_path" > /dev/null <<EOF
# Managed by makeApacheRedirects.sh - do not hand-edit; re-run the script instead.

# All HTTP (port 80) for every managed name -> canonical HTTPS host.
<VirtualHost *:80>
    ServerName $canonical
${alias_line}
    RewriteEngine On
    RewriteRule ^ https://$canonical%{REQUEST_URI} [R=301,L]
</VirtualHost>

<IfModule mod_ssl.c>
${apex_https_block}# Canonical HTTPS site - serves the actual content.
<VirtualHost *:443>
    ServerName $canonical
    DocumentRoot $docroot

    <Directory $docroot>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/$FINALDOMAIN.error.log
    CustomLog ${APACHE_LOG_DIR}/$FINALDOMAIN.access.log combined

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$cert_name/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$cert_name/privkey.pem
    Include /etc/letsencrypt/options-ssl-apache.conf
</VirtualHost>
</IfModule>
EOF
}

test_and_reload_apache() {
    echo "Running apache config test..."
    sudo apache2ctl configtest
    echo "Reloading apache..."
    sudo systemctl reload apache2
}

enable_apache_bits() {
    echo "Enabling required Apache modules..."
    sudo a2enmod ssl >/dev/null
    sudo a2enmod rewrite >/dev/null
}

require_root_tools

read -rp "Please enter the domain name: " DOMAIN
DOMAIN=$(normalize_domain "$DOMAIN")

if [[ -z "$DOMAIN" ]]; then
    echo "Error: domain name is required."
    exit 1
fi

build_domain_vars "$DOMAIN"

echo
echo "Canonical (served) host : $CANONICAL"
if [[ "$IS_WWW_PAIR" == "yes" ]]; then
    echo "Apex (redirects here)   : $BASE_DOMAIN"
fi
echo "Certificate name        : $CERT_NAME"
echo "Config / log name       : $FINALDOMAIN"
echo

read -rp "Please enter the document root [$WEB_BASE/$FINALDOMAIN]: " DOCROOT
DOCROOT="${DOCROOT:-$WEB_BASE/$FINALDOMAIN}"

if [[ ! -d "$DOCROOT" ]]; then
    echo
    if confirm "Document root does not exist. Create $DOCROOT?"; then
        sudo mkdir -p "$DOCROOT"
        sudo chown "$USER":"$USER" "$DOCROOT" || true
        sudo chmod 0775 "$DOCROOT"
        echo "Created $DOCROOT"
    else
        echo "Cannot continue without a document root."
        exit 1
    fi
fi

VHOST_PATH="$APACHE_SITES_AVAILABLE/$FINALDOMAIN.conf"
CERT_LIVE_DIR="/etc/letsencrypt/live/$CERT_NAME"

# Build the list of -d arguments for certbot. For a www pair we MUST include the
# apex so the issued certificate covers both example.com and www.example.com.
CERTBOT_DOMAIN_ARGS=(-d "$CANONICAL")
if [[ "$IS_WWW_PAIR" == "yes" ]]; then
    CERTBOT_DOMAIN_ARGS+=(-d "$BASE_DOMAIN")
fi

enable_apache_bits

# Idempotency: only the *first* setup needs the throwaway HTTP-only vhost so the
# ACME HTTP-01 challenge can be answered before any SSL config exists. On re-runs
# (cert already present) we leave the live config untouched and go straight to a
# certbot renew/expand so we never knock a working site back down to plain HTTP.
HAVE_CERT="no"
if sudo test -f "$CERT_LIVE_DIR/fullchain.pem"; then
    HAVE_CERT="yes"
fi

if [[ "$HAVE_CERT" == "no" ]]; then
    echo
    echo "No existing certificate found at $CERT_LIVE_DIR."
    echo "Writing temporary HTTP vhost at: $VHOST_PATH"
    write_temp_http_vhost "$VHOST_PATH" "$CANONICAL" \
        "$([[ "$IS_WWW_PAIR" == "yes" ]] && echo "$BASE_DOMAIN")" "$DOCROOT"

    if ! sudo test -L "/etc/apache2/sites-enabled/$FINALDOMAIN.conf"; then
        echo "Enabling site..."
        sudo a2ensite "$FINALDOMAIN.conf" >/dev/null
    fi

    test_and_reload_apache
else
    echo
    echo "Existing certificate found at $CERT_LIVE_DIR; leaving current config in place."
    if ! sudo test -L "/etc/apache2/sites-enabled/$FINALDOMAIN.conf"; then
        echo "Enabling site..."
        sudo a2ensite "$FINALDOMAIN.conf" >/dev/null
        test_and_reload_apache
    fi
fi

echo
echo "Requesting/updating certificate with certbot..."
echo "Certificate name : $CERT_NAME"
echo "Domains to cover :"
echo "  - $CANONICAL"
if [[ "$IS_WWW_PAIR" == "yes" ]]; then
    echo "  - $BASE_DOMAIN"
fi
echo

if confirm "Run certbot now?"; then
    # certonly  : obtain/renew the cert but never let certbot rewrite our vhosts.
    # --cert-name: keep a single, stable lineage so re-runs update in place.
    # --expand  : if an older cert is missing a name (e.g. the apex), reissue to add it.
    # --keep-until-expiring: a no-op rerun won't pointlessly hit rate limits.
    sudo certbot certonly --apache \
        --cert-name "$CERT_NAME" \
        --expand --keep-until-expiring \
        "${CERTBOT_DOMAIN_ARGS[@]}"
else
    echo "Skipped certbot."
    if [[ "$HAVE_CERT" == "no" ]]; then
        echo "Temporary HTTP site is active, but HTTPS config was not finalized."
        exit 0
    fi
    echo "Continuing with the existing certificate."
fi

if ! sudo test -f "$CERT_LIVE_DIR/fullchain.pem"; then
    echo
    echo "Error: certificate not found at $CERT_LIVE_DIR after certbot."
    echo "Final HTTPS vhost was NOT written so Apache keeps a valid config."
    echo "Fix the certbot issue and just re-run this script."
    exit 1
fi

echo
echo "Writing final redirect + SSL vhost..."
write_final_vhost "$VHOST_PATH" "$CANONICAL" "$BASE_DOMAIN" "$DOCROOT" "$CERT_NAME" "$IS_WWW_PAIR"

if ! sudo test -L "/etc/apache2/sites-enabled/$FINALDOMAIN.conf"; then
    echo "Enabling site..."
    sudo a2ensite "$FINALDOMAIN.conf" >/dev/null
fi

test_and_reload_apache

echo
echo "Done."
echo "Vhost file       : $VHOST_PATH"
echo "Canonical host   : https://$CANONICAL"
if [[ "$IS_WWW_PAIR" == "yes" ]]; then
    echo "Redirects        : http(s)://$BASE_DOMAIN  ->  https://$CANONICAL"
    echo "                   http://$CANONICAL       ->  https://$CANONICAL"
fi
echo "Certificate      : $CERT_LIVE_DIR (covers ${CERTBOT_DOMAIN_ARGS[*]//-d /})"
echo "Document root    : $DOCROOT"
echo
sudo systemctl --no-pager --full status apache2 | sed -n '1,20p'


