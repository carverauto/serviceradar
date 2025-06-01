import requests
import re
import os
import logging
from urllib.parse import quote
import time
from googleapiclient.discovery import build
from urllib.parse import urlparse

# Setup logging
logging.basicConfig(filename='logo_fetch.log', level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

# Directory to save logos
LOGO_DIR = "vendor_logos"
os.makedirs(LOGO_DIR, exist_ok=True)

# Path to local oui.txt file
OUI_FILE_PATH = "./oui.txt"

# Google Custom Search JSON API credentials
# Replace with your API key from Google Cloud Console
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
# Replace with your Custom Search Engine ID from https://programmablesearchengine.google.com
# If you don't have a CSE ID, create one by following these steps:
# 1. Go to https://programmablesearchengine.google.com/controlpanel/create
# 2. Create a search engine with "Search the entire web" enabled
# 3. Copy the "Search engine ID" from the control panel
GOOGLE_CSE_ID = os.getenv("GOOGLE_CSE_ID")

def clean_vendor_name(vendor):
    """Clean vendor name as a fallback for domain guessing."""
    suffixes = ["Inc.", "Co.", "Ltd.", "Corporation", "LLC", "GmbH", "S.A.", "Pty", "Shanghai", "Headquarters"]
    vendor = vendor.strip()
    for suffix in suffixes:
        vendor = vendor.replace(suffix, "").strip()
    vendor = re.sub(r'[^\w\s]', '', vendor)
    vendor = vendor.replace(" ", "").lower()
    return f"{vendor}.com"

def infer_domain(vendor):
    """Infer domain name using Google Custom Search JSON API."""
    if not GOOGLE_API_KEY or not GOOGLE_CSE_ID:
        logging.error("Missing GOOGLE_API_KEY or GOOGLE_CSE_ID. Using fallback.")
        return clean_vendor_name(vendor)

    try:
        # Initialize Google Custom Search API
        service = build("customsearch", "v1", developerKey=GOOGLE_API_KEY)
        query = f"{vendor} official website"

        # Perform search
        result = service.cse().list(q=query, cx=GOOGLE_CSE_ID, num=1).execute()

        # Extract the top result's URL
        if "items" in result and len(result["items"]) > 0:
            url = result["items"][0]["link"]
            # Parse the domain from the URL
            domain = urlparse(url).netloc
            # Remove 'www.' prefix if present
            if domain.startswith("www."):
                domain = domain[4:]
            logging.info(f"Inferred domain for '{vendor}': {domain}")
            return domain
        else:
            logging.warning(f"No search results for '{vendor}'")
            # Fallback to heuristic
            fallback_domain = clean_vendor_name(vendor)
            logging.info(f"Using fallback domain for '{vendor}': {fallback_domain}")
            return fallback_domain

    except Exception as e:
        logging.error(f"Error querying Google API for '{vendor}': {e}")
        # Fallback to heuristic
        fallback_domain = clean_vendor_name(vendor)
        logging.info(f"Using fallback domain for '{vendor}': {fallback_domain}")
        return fallback_domain

def fetch_logo(domain, oui, vendor):
    """Fetch logo from Clearbit Logo API and save locally."""
    logo_url = f"https://logo.clearbit.com/{quote(domain)}"
    # Sanitize vendor name for filename
    safe_vendor = re.sub(r'[^\w\-]', '_', vendor)  # Replace invalid chars with underscore
    filename = os.path.join(LOGO_DIR, f"{oui}_{safe_vendor}.png")

    try:
        response = requests.get(logo_url, timeout=5)
        if response.status_code == 200:
            with open(filename, 'wb') as f:
                f.write(response.content)
            logging.info(f"Downloaded logo for {vendor} ({domain}) to {filename}")
            return True
        else:
            logging.warning(f"No logo found for {vendor} ({domain})")
            return False
    except requests.RequestException as e:
        logging.error(f"Error fetching logo for {vendor} ({domain}): {e}")
        return False

def parse_oui_lines(lines):
    """Parse OUI file lines into a list of dictionaries."""
    vendors = []
    current_vendor = None

    for line in lines:
        oui_match = re.match(r'^([\w-]{8})\s+\(hex\)\s+(.+)$', line)
        if oui_match:
            oui, vendor = oui_match.groups()
            oui = oui.replace("-", "").upper()
            current_vendor = {"oui": oui, "vendor": vendor.strip(), "address": []}
            vendors.append(current_vendor)
            continue

        if current_vendor and line.strip():
            current_vendor["address"].append(line.strip())

    return vendors

def main():
    # Read local oui.txt file
    logging.info(f"Reading OUI file from {OUI_FILE_PATH}...")
    try:
        with open(OUI_FILE_PATH, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        print(f"Error: {OUI_FILE_PATH} not found. Please ensure the file exists.")
        logging.error(f"OUI file not found: {OUI_FILE_PATH}")
        return
    except Exception as e:
        print(f"Error reading {OUI_FILE_PATH}: {e}")
        logging.error(f"Error reading OUI file: {e}")
        return

    # Parse OUI data
    logging.info("Parsing OUI file...")
    vendors = parse_oui_lines(lines)
    print(f"Found {len(vendors)} OUI entries.")

    # Process each vendor
    successes = 0
    failures = 0
    for vendor in vendors[:100]:  # Limit to 100 for Google API free tier
        oui = vendor["oui"]
        vendor_name = vendor["vendor"]

        # Infer domain using Google Search API
        domain = infer_domain(vendor_name)

        # Fetch logo
        if fetch_logo(domain, oui, vendor_name):
            successes += 1
        else:
            failures += 1

        # Respect API rate limits
        time.sleep(1)

    print(f"Processed {successes + failures} vendors: {successes} successes, {failures} failures.")
    print(f"Check '{LOGO_DIR}' for downloaded logos and 'logo_fetch.log' for details.")

if __name__ == "__main__":
    main()
