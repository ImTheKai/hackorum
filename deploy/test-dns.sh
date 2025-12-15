#!/bin/bash
# Script to test all required DNS records for email delivery

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

DOMAIN=${MAIL_DOMAIN:-example.com}
MAIL_HOST=${MAIL_HOSTNAME:-mail.example.com}
DKIM_SEL=${DKIM_SELECTOR:-mail}

echo "==================================================================="
echo -e "${BLUE}DNS Configuration Test for Email Delivery${NC}"
echo "==================================================================="
echo ""
echo "Domain: $DOMAIN"
echo "Mail Host: $MAIL_HOST"
echo "DKIM Selector: $DKIM_SEL"
echo ""

# Function to check DNS record
check_record() {
    local type=$1
    local name=$2
    local expected=$3
    local description=$4

    echo -e "${YELLOW}Checking $description...${NC}"
    result=$(dig +short $type $name 2>/dev/null || echo "")

    if [ -z "$result" ]; then
        echo -e "${RED}❌ FAIL: No $type record found for $name${NC}"
        return 1
    else
        echo -e "${GREEN}✅ PASS: Found $type record${NC}"
        echo "   $result"

        if [ -n "$expected" ]; then
            if echo "$result" | grep -q "$expected"; then
                echo -e "${GREEN}   Contains expected value: $expected${NC}"
            else
                echo -e "${YELLOW}   ⚠️  Does not contain: $expected${NC}"
            fi
        fi
        return 0
    fi
    echo ""
}

# Track results
total=0
passed=0

# Test 1: A record for mail server
((total++))
if check_record "A" "$MAIL_HOST" "" "A Record (Mail Server)"; then
    ((passed++))
fi
echo ""

# Test 2: SPF record
((total++))
echo -e "${YELLOW}Checking SPF Record...${NC}"
spf=$(dig +short TXT "$DOMAIN" | grep "v=spf1" || echo "")
if [ -z "$spf" ]; then
    echo -e "${RED}❌ FAIL: No SPF record found${NC}"
else
    echo -e "${GREEN}✅ PASS: Found SPF record${NC}"
    echo "   $spf"

    # Check if it includes the mail server
    if echo "$spf" | grep -q "a:$MAIL_HOST\|ip4:\|mx"; then
        echo -e "${GREEN}   Includes mail server authorization${NC}"
    else
        echo -e "${YELLOW}   ⚠️  May not authorize your mail server${NC}"
    fi

    # Check policy
    if echo "$spf" | grep -q "~all"; then
        echo -e "${YELLOW}   Policy: ~all (soft fail - good for testing)${NC}"
        echo -e "${YELLOW}   Consider changing to -all after testing${NC}"
    elif echo "$spf" | grep -q "\-all"; then
        echo -e "${GREEN}   Policy: -all (hard fail - recommended for production)${NC}"
    fi
    ((passed++))
fi
echo ""

# Test 3: DKIM record
((total++))
dkim_name="${DKIM_SEL}._domainkey.$DOMAIN"
echo -e "${YELLOW}Checking DKIM Record...${NC}"
dkim=$(dig +short TXT "$dkim_name" | grep "v=DKIM1" || echo "")
if [ -z "$dkim" ]; then
    echo -e "${RED}❌ FAIL: No DKIM record found for $dkim_name${NC}"
    echo -e "${YELLOW}   Run ./get-dkim-key.sh to get your DKIM public key${NC}"
else
    echo -e "${GREEN}✅ PASS: Found DKIM record${NC}"
    echo "   ${dkim:0:80}..."
    ((passed++))
fi
echo ""

# Test 4: DMARC record
((total++))
dmarc_name="_dmarc.$DOMAIN"
echo -e "${YELLOW}Checking DMARC Record...${NC}"
dmarc=$(dig +short TXT "$dmarc_name" | grep "v=DMARC1" || echo "")
if [ -z "$dmarc" ]; then
    echo -e "${RED}❌ FAIL: No DMARC record found for $dmarc_name${NC}"
else
    echo -e "${GREEN}✅ PASS: Found DMARC record${NC}"
    echo "   $dmarc"

    # Check policy
    if echo "$dmarc" | grep -q "p=none"; then
        echo -e "${YELLOW}   Policy: none (monitoring only - good for testing)${NC}"
    elif echo "$dmarc" | grep -q "p=quarantine"; then
        echo -e "${GREEN}   Policy: quarantine (recommended)${NC}"
    elif echo "$dmarc" | grep -q "p=reject"; then
        echo -e "${GREEN}   Policy: reject (most strict)${NC}"
    fi
    ((passed++))
fi
echo ""

# Test 5: PTR record (reverse DNS)
((total++))
echo -e "${YELLOW}Checking PTR Record (Reverse DNS)...${NC}"
# Get IP of mail host
mail_ip=$(dig +short A "$MAIL_HOST" | head -n1)
if [ -z "$mail_ip" ]; then
    echo -e "${RED}❌ FAIL: Could not resolve mail server IP${NC}"
else
    echo "   Mail server IP: $mail_ip"
    ptr=$(dig +short -x "$mail_ip" || echo "")
    if [ -z "$ptr" ]; then
        echo -e "${RED}❌ FAIL: No PTR record found for $mail_ip${NC}"
        echo -e "${YELLOW}   Contact your hosting provider to set PTR: $mail_ip → $MAIL_HOST${NC}"
    else
        echo -e "${GREEN}✅ PASS: Found PTR record${NC}"
        echo "   $mail_ip → $ptr"

        # Check if PTR matches mail host
        if echo "$ptr" | grep -q "$MAIL_HOST"; then
            echo -e "${GREEN}   PTR matches mail hostname${NC}"
        else
            echo -e "${YELLOW}   ⚠️  PTR ($ptr) doesn't match mail host ($MAIL_HOST)${NC}"
        fi
        ((passed++))
    fi
fi
echo ""

# Summary
echo "==================================================================="
echo -e "${BLUE}Summary${NC}"
echo "==================================================================="
echo -e "Tests Passed: ${GREEN}$passed${NC} / $total"
echo ""

if [ $passed -eq $total ]; then
    echo -e "${GREEN}🎉 All tests passed! Your DNS is configured correctly.${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Send a test email to https://www.mail-tester.com/"
    echo "2. Check your score (aim for 10/10)"
    echo "3. Review any recommendations"
elif [ $passed -ge 3 ]; then
    echo -e "${YELLOW}⚠️  Most tests passed, but some records are missing or incorrect.${NC}"
    echo ""
    echo "Your emails should work but may have deliverability issues."
    echo "Fix the failing tests above for production use."
else
    echo -e "${RED}❌ Several DNS records are missing or incorrect.${NC}"
    echo ""
    echo "Email delivery may not work or emails will go to spam."
    echo "See DNS_RECORDS.md for setup instructions."
fi
echo ""

# Additional checks
echo "==================================================================="
echo -e "${BLUE}Additional Recommendations${NC}"
echo "==================================================================="
echo ""

# Check if using a common email testing tool
echo "Test your email deliverability:"
echo "  • https://www.mail-tester.com/ - Get a score out of 10"
echo "  • https://mxtoolbox.com/SuperTool.aspx - Check DNS and blacklists"
echo "  • https://toolbox.googleapps.com/apps/checkmx/ - Google's MX check"
echo ""

# Check if mail service is running
if docker compose ps mail 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✅ Mail service is running${NC}"
else
    echo -e "${YELLOW}⚠️  Mail service is not running. Start with: docker compose up -d mail${NC}"
fi
echo ""

exit $((total - passed))
