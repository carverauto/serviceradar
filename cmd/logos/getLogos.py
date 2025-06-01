import requests
import re
import os
import logging
import json
from urllib.parse import quote
import time
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from urllib.parse import urlparse

# Setup logging
logging.basicConfig(filename='logo_fetch.log', level=logging.DEBUG,
                    format='%(asctime)s - %(levelname)s - %(message)s')

# Directory to save logos
LOGO_DIR = "vendor_logos"
os.makedirs(LOGO_DIR, exist_ok=True)
logging.debug(f"Ensured logo directory exists: {LOGO_DIR}")

# Path to local oui.txt file
OUI_FILE_PATH = "./oui.txt"

# Path to save the vendor-to-OUI mapping
MAPPING_FILE_PATH = "vendor_to_oui_mapping.json"

# Google Custom Search JSON API credentials
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
GOOGLE_CSE_ID = os.getenv("GOOGLE_CSE_ID")

def clean_vendor_name(vendor):
    """Clean vendor name as a fallback for domain guessing."""
    logging.debug(f"Cleaning vendor name: {vendor}")
    suffixes = ["Inc.", "Co.", "Ltd.", "Corporation", "LLC", "GmbH", "S.A.", "Pty", "Shanghai", "Headquarters"]
    cleaned = vendor.strip()
    for suffix in suffixes:
        cleaned = cleaned.replace(suffix, "").strip()
    cleaned = re.sub(r'[^\w\s]', '', cleaned)
    cleaned = cleaned.replace(" ", "").lower()
    result = f"{cleaned}.com"
    logging.debug(f"Cleaned vendor name to: {result}")
    return result

def infer_domain(vendor, retries=3, backoff_factor=2):
    """Infer domain name using Google Custom Search JSON API with retry logic."""
    logging.debug(f"Starting domain inference for vendor: {vendor}")
    if not GOOGLE_API_KEY or not GOOGLE_CSE_ID:
        logging.error("Missing GOOGLE_API_KEY or GOOGLE_CSE_ID. Using fallback.")
        print(f"Warning: Missing Google API credentials for {vendor}. Falling back to heuristic.")
        return clean_vendor_name(vendor)

    for attempt in range(retries):
        try:
            logging.debug("Initializing Google Custom Search API")
            service = build("customsearch", "v1", developerKey=GOOGLE_API_KEY)
            query = f"{vendor} official website"
            logging.debug(f"Search query: {query}")
            result = service.cse().list(q=query, cx=GOOGLE_CSE_ID, num=1).execute()
            logging.debug(f"Google API response: {result}")

            if "items" in result and len(result["items"]) > 0:
                url = result["items"][0]["link"]
                domain = urlparse(url).netloc
                if domain.startswith("www."):
                    domain = domain[4:]
                logging.info(f"Inferred domain for '{vendor}': {domain}")
                print(f"Success: Inferred domain '{domain}' for '{vendor}'")
                return domain
            else:
                logging.warning(f"No search results for '{vendor}'")
                print(f"Warning: No search results for '{vendor}'. Falling back to heuristic.")
                fallback_domain = clean_vendor_name(vendor)
                logging.info(f"Using fallback domain for '{vendor}': {fallback_domain}")
                return fallback_domain

        except HttpError as e:
            if e.resp.status == 429:  # Rate limit exceeded
                sleep_time = backoff_factor ** attempt
                logging.warning(f"Rate limit exceeded for '{vendor}'. Retrying in {sleep_time} seconds (attempt {attempt + 1}/{retries})")
                print(f"Rate limit exceeded for '{vendor}'. Retrying in {sleep_time} seconds (attempt {attempt + 1}/{retries})")
                time.sleep(sleep_time)
                continue
            else:
                logging.error(f"Google API error for '{vendor}': {e}")
                print(f"Error: Google API error for '{vendor}': {e}. Falling back to heuristic.")
                fallback_domain = clean_vendor_name(vendor)
                logging.info(f"Using fallback domain for '{vendor}': {fallback_domain}")
                return fallback_domain
        except Exception as e:
            logging.error(f"Error querying Google API for '{vendor}': {e}")
            print(f"Error: Failed to query Google API for '{vendor}': {e}. Falling back to heuristic.")
            fallback_domain = clean_vendor_name(vendor)
            logging.info(f"Using fallback domain for '{vendor}': {fallback_domain}")
            return fallback_domain

    logging.error(f"Failed to infer domain for '{vendor}' after {retries} attempts. Using fallback.")
    print(f"Error: Failed to infer domain for '{vendor}' after {retries} attempts. Using fallback.")
    return clean_vendor_name(vendor)

def fetch_logo(domain, oui, vendor):
    """Fetch logo from Clearbit Logo API and save locally."""
    logging.debug(f"Fetching logo for vendor: {vendor}, OUI: {oui}, domain: {domain}")
    logo_url = f"https://logo.clearbit.com/{quote(domain)}"
    safe_vendor = re.sub(r'[^\w\-]', '_', vendor)
    filename = os.path.join(LOGO_DIR, f"{safe_vendor}.png")
    logging.debug(f"Generated filename: {filename}")

    try:
        logging.debug(f"Sending request to Clearbit API: {logo_url}")
        response = requests.get(logo_url, timeout=5)
        logging.debug(f"Clearbit API response status: {response.status_code}")
        if response.status_code == 200:
            try:
                with open(filename, 'wb') as f:
                    f.write(response.content)
                logging.info(f"Downloaded logo for {vendor} ({domain}) to {filename}")
                print(f"Success: Saved logo for '{vendor}' to '{filename}'")
                return True, filename
            except FileNotFoundError as e:
                logging.error(f"Failed to save logo for {vendor} ({domain}) to {filename}: {e}")
                print(f"Error: Failed to save logo for '{vendor}' to '{filename}': {e}")
                return False, None
        else:
            logging.warning(f"No logo found for {vendor} ({domain}), status code: {response.status_code}")
            print(f"Warning: No logo found for '{vendor}' ({domain}), status: {response.status_code}")
            return False, None
    except requests.RequestException as e:
        logging.error(f"Error fetching logo for {vendor} ({domain}): {e}")
        print(f"Error: Failed to fetch logo for '{vendor}' ({domain}): {e}")
        return False, None

def parse_oui_lines(lines):
    """Parse OUI file lines into a list of dictionaries."""
    logging.debug("Starting OUI file parsing")
    vendors = []
    current_vendor = None

    for line in lines:
        oui_match = re.match(r'^([\w-]{8})\s+\(hex\)\s+(.+)$', line)
        if oui_match:
            oui, vendor = oui_match.groups()
            oui = oui.replace("-", "").upper()
            current_vendor = {"oui": oui, "vendor": vendor.strip(), "address": []}
            vendors.append(current_vendor)
            logging.debug(f"Parsed OUI: {oui}, Vendor: {vendor}")
            continue

        if current_vendor and line.strip():
            current_vendor["address"].append(line.strip())
            logging.debug(f"Added address line for {current_vendor['vendor']}: {line.strip()}")

    logging.info(f"Parsed {len(vendors)} OUI entries")
    return vendors

def main():
    # Read local oui.txt file
    logging.info(f"Reading OUI file from {OUI_FILE_PATH}")
    print(f"Reading OUI file: {OUI_FILE_PATH}")
    try:
        with open(OUI_FILE_PATH, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
        logging.debug(f"Read {len(lines)} lines from OUI file")
    except FileNotFoundError:
        logging.error(f"OUI file not found: {OUI_FILE_PATH}")
        print(f"Error: {OUI_FILE_PATH} not found. Please ensure the file exists.")
        return
    except Exception as e:
        logging.error(f"Error reading OUI file: {e}")
        print(f"Error reading {OUI_FILE_PATH}: {e}")
        return

    # Parse OUI data
    logging.info("Parsing OUI file")
    vendors = parse_oui_lines(lines)
    total_vendors = len(vendors)
    print(f"Found {total_vendors} OUI entries.")

    # Track processed vendors and map vendors to OUIs and logos
    processed_vendors = set()
    vendor_to_oui_mapping = {}
    successes = 0
    failures = 0
    skipped = 0

    for i, vendor in enumerate(vendors, 1):  # Process all vendors
        oui = vendor["oui"]
        vendor_name = vendor["vendor"]
        normalized_vendor = re.sub(r'[^\w]', '', vendor_name).lower()
        progress = (i / total_vendors) * 100
        logging.info(f"Processing vendor {i}/{total_vendors} ({progress:.2f}%): {vendor_name} (OUI: {oui}, Normalized: {normalized_vendor})")
        print(f"Processing vendor {i}/{total_vendors} ({progress:.2f}%): {vendor_name} (Normalized: {normalized_vendor})")

        # Initialize or update the vendor entry in the mapping
        if vendor_name not in vendor_to_oui_mapping:
            vendor_to_oui_mapping[vendor_name] = {
                "ouis": [],
                "logo_file": None
            }
        vendor_to_oui_mapping[vendor_name]["ouis"].append(oui)
        logging.debug(f"Updated vendor mapping for {vendor_name}: {vendor_to_oui_mapping[vendor_name]}")

        # Skip fetching logo if we've already processed this vendor
        if normalized_vendor in processed_vendors:
            logging.info(f"Skipping duplicate vendor: {vendor_name} (Normalized: {normalized_vendor})")
            print(f"Skipping: Already processed vendor '{vendor_name}' (Normalized: {normalized_vendor})")
            skipped += 1
            continue

        processed_vendors.add(normalized_vendor)
        logging.debug(f"Processed vendors set: {processed_vendors}")

        # Infer domain using Google Search API
        domain = infer_domain(vendor_name)
        logging.debug(f"Selected domain for '{vendor_name}': {domain}")

        # Fetch logo
        success, logo_filename = fetch_logo(domain, oui, vendor_name)
        if success:
            successes += 1
            vendor_to_oui_mapping[vendor_name]["logo_file"] = logo_filename
        else:
            failures += 1

        # Respect API rate limits (already handled in infer_domain, but keep a small delay)
        logging.debug("Sleeping for 1 second to respect API rate limits")
        time.sleep(1)

    # Save the vendor-to-OUI mapping to a JSON file
    try:
        with open(MAPPING_FILE_PATH, 'w', encoding='utf-8') as f:
            json.dump(vendor_to_oui_mapping, f, indent=4)
        logging.info(f"Saved vendor-to-OUI mapping to {MAPPING_FILE_PATH}")
        print(f"Saved vendor-to-OUI mapping to {MAPPING_FILE_PATH}")
    except Exception as e:
        logging.error(f"Failed to save vendor-to-OUI mapping: {e}")
        print(f"Error: Failed to save vendor-to-OUI mapping: {e}")

    logging.info(f"Processed {successes + failures + skipped} vendors: {successes} successes, {failures} failures, {skipped} skipped duplicates")
    print(f"Processed {successes + failures + skipped} vendors: {successes} successes, {failures} failures, {skipped} skipped duplicates.")
    print(f"Check '{LOGO_DIR}' for downloaded logos, '{MAPPING_FILE_PATH}' for the vendor-to-OUI mapping, and 'logo_fetch.log' for details.")

if __name__ == "__main__":
    main()
