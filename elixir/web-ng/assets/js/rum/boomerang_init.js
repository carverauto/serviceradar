import {registerServiceRadarTrace} from "./serviceradar_trace.js";

const DEFAULT_BEACON_URL = "/rum/v1/beacon";

export function buildBeaconUrl(baseUrl, siteKey) {
  const base =
    typeof baseUrl === "string" && baseUrl.trim() !== ""
      ? baseUrl.trim()
      : DEFAULT_BEACON_URL;

  if (!siteKey) return base;

  const hasKeyParam = /[?&](?:key|site_key|sr\.key)=/i.test(base);
  if (hasKeyParam) return base;

  const separator = base.indexOf("?") === -1 ? "?" : "&";
  return `${base}${separator}key=${encodeURIComponent(String(siteKey))}`;
}

export function normalizeSampleRate(raw) {
  if (raw === undefined || raw === null || raw === "") return 1.0;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return 1.0;
  if (parsed <= 0) return 0;
  if (parsed >= 1) return 1.0;
  return parsed;
}

export function initServiceRadarBoomerang(win) {
  if (!win || !win.BOOMR) return false;

  const boomr = win.BOOMR;
  const srConfig = win.BOOMR_config && win.BOOMR_config.ServiceRadar;
  if (!srConfig || !srConfig.siteKey) {
    return false;
  }

  registerServiceRadarTrace(win);

  const sampleRate = normalizeSampleRate(srConfig.sampleRate);
  if (sampleRate <= 0 || (sampleRate < 1.0 && Math.random() >= sampleRate)) {
    srConfig.sampledOut = true;
    return false;
  }

  const siteKey = String(srConfig.siteKey).trim();
  if (!siteKey) return false;

  const tracePropagateOrigins = Array.isArray(srConfig.tracePropagateOrigins)
    ? srConfig.tracePropagateOrigins
    : [];
  const beaconUrl = buildBeaconUrl(srConfig.beaconUrl || DEFAULT_BEACON_URL, siteKey);

  if (typeof boomr.addVar === "function") {
    boomr.addVar("sr.key", siteKey);
  }

  if (typeof boomr.init === "function") {
    boomr.init({
      beacon_url: beaconUrl,
      beacon_type: "POST",
      autorun: srConfig.autorun !== false,
      PageParams: {
        xhr: "all",
      },
      AutoXHR: {
        alwaysSendXhr: true,
      },
      ServiceRadarTrace: {
        tracePropagateOrigins,
        beaconUrl,
      },
    });
  }

  return true;
}

if (typeof window !== "undefined" && window.BOOMR) {
  initServiceRadarBoomerang(window);
}
