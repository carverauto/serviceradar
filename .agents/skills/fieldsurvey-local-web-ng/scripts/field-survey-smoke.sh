#!/usr/bin/env bash
set -euo pipefail

base_url="${BASE_URL:-http://localhost:4000}"
email="${SERVICERADAR_SMOKE_EMAIL:-root@localhost}"
password="${SERVICERADAR_SMOKE_PASSWORD:-serviceradar2026!}"
out_dir="${OUT_DIR:-.playwright-cli}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd playwright-cli
mkdir -p "$out_dir"

playwright-cli open "${base_url}/dashboard" >/dev/null

if playwright-cli --raw eval "Boolean(document.querySelector('#user_email'))" | grep -q true; then
  playwright-cli fill "#user_email" "$email" >/dev/null
  playwright-cli fill "#user_password" "$password" >/dev/null
  playwright-cli click "button[type=submit]" >/dev/null
fi

playwright-cli goto "${base_url}/dashboard" >/dev/null
playwright-cli run-code "async page => await page.waitForFunction(() => document.querySelector('[data-testid=fieldsurvey-heatmap]')?.querySelectorAll('line').length > 0, null, {timeout: 15000})" >/dev/null

playwright-cli resize 2048 1400 >/dev/null
playwright-cli screenshot --filename="${out_dir}/fieldsurvey-dashboard-local.png" >/dev/null

dashboard_check="$(
  playwright-cli --raw eval "(() => {
    const cards = Array.from(document.querySelectorAll('[data-testid=fieldsurvey-heatmap]'));
    if (cards.length === 0) throw new Error('dashboard FieldSurvey heatmap card is missing');
    const card = cards[0];
    const rect = card.getBoundingClientRect();
    const floorplan = card.querySelectorAll('line').length;
    if (floorplan === 0) throw new Error('dashboard FieldSurvey card has no floorplan segments');
    return JSON.stringify({width: rect.width, height: rect.height, floorplan});
  })()"
)"
if [[ "$dashboard_check" == Error:* ]]; then
  printf 'Dashboard smoke failed: %s\n' "$dashboard_check" >&2
  exit 1
fi

playwright-cli goto "${base_url}/settings/networks/field-survey" >/dev/null
playwright-cli click "text=Preview" >/dev/null
settings_check="$(
  playwright-cli --raw eval "(() => {
    const text = document.body.innerText;
    if (!text.includes('Query resolves to a persisted FieldSurvey raster')) {
      throw new Error('settings preview did not resolve a persisted raster');
    }
    return JSON.stringify({preview: 'ok'});
  })()"
)"
if [[ "$settings_check" == Error:* ]]; then
  printf 'Settings smoke failed: %s\n' "$settings_check" >&2
  exit 1
fi

playwright-cli goto "${base_url}/spatial/field-surveys" >/dev/null
playwright-cli run-code "async page => await page.waitForFunction(() => document.body.innerText.includes('Survey Sessions'), null, {timeout: 15000})" >/dev/null
playwright-cli screenshot --filename="${out_dir}/fieldsurvey-review-local.png" >/dev/null

review_check="$(
  playwright-cli --raw eval "(() => {
    const text = document.body.innerText;
    if (!text.includes('FieldSurvey Review')) throw new Error('FieldSurvey review page did not load');
    if (!text.includes('Survey Sessions')) throw new Error('FieldSurvey review sessions are missing');
    return JSON.stringify({floorplanLines: document.querySelectorAll('line').length, text: text.slice(0, 120)});
  })()"
)"
if [[ "$review_check" == Error:* ]]; then
  printf 'Review smoke failed: %s\n' "$review_check" >&2
  exit 1
fi

printf 'Dashboard smoke: %s\n' "$dashboard_check"
printf 'Settings smoke: %s\n' "$settings_check"
printf 'Review smoke: %s\n' "$review_check"
printf 'Screenshots: %s/fieldsurvey-dashboard-local.png %s/fieldsurvey-review-local.png\n' "$out_dir" "$out_dir"
