#!/bin/bash
# Script to extract DKIM public key from the mail container
# Run this after starting the mail service for the first time

set -e

echo "==================================================================="
echo "DKIM Public Key for DNS Configuration"
echo "==================================================================="
echo ""
echo "Retrieving DKIM key from mail container..."
echo ""

# Try to get the DKIM key
KEY=$(docker compose exec -T mail cat /etc/opendkim/keys/mail.txt 2>/dev/null || \
      docker compose exec -T mail sh -c 'cat /etc/opendkim/keys/*.txt' 2>/dev/null || \
      echo "ERROR: Could not retrieve DKIM key")

if [[ "$KEY" == "ERROR:"* ]]; then
    echo "❌ Failed to retrieve DKIM key!"
    echo ""
    echo "Make sure the mail container is running:"
    echo "  docker compose ps mail"
    echo ""
    echo "Check mail container logs:"
    echo "  docker compose logs mail"
    exit 1
fi

echo "Raw key file content:"
echo "-------------------------------------------------------------------"
echo "$KEY"
echo "-------------------------------------------------------------------"
echo ""

# Extract the DNS record value (remove line breaks, quotes, and extra spaces)
DNS_VALUE=$(echo "$KEY" | grep -v "^;" | tr -d '\n' | sed 's/.*TXT[[:space:]]*(//' | sed 's/[[:space:]]*)[[:space:]]*;.*//' | tr -d '"' | sed 's/[[:space:]]\+/ /g' | xargs)

echo "DNS Record to add:"
echo "-------------------------------------------------------------------"
echo "Type: TXT"
echo "Name: mail._domainkey"
echo "Value: $DNS_VALUE"
echo "TTL: 3600"
echo "-------------------------------------------------------------------"
echo ""
echo "✅ Copy the 'Value' line above and add it to your DNS provider"
echo ""
echo "Note: The selector 'mail' must match your DKIM_SELECTOR in .env"
echo "      If using a different selector, update the Name field accordingly"
echo ""
