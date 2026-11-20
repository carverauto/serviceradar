import {registerServiceRadarTrace} from "./serviceradar_trace.js";

export function buildBeaconUrl(baseUrl, siteKey) {
  const base = typeof baseUrl === "string" ? baseUrl.trim() : "";
  if (!base) return "";

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

const initializedBoomerangInstances = new WeakSet();
const pendingLateInitWindows = new WeakSet();

export function initServiceRadarBoomerang(win) {
  if (!win || !win.BOOMR) return false;

  const boomr = win.BOOMR;
  if (initializedBoomerangInstances.has(boomr)) {
    return true;
  }

  const srConfig = win.BOOMR_config && win.BOOMR_config.ServiceRadar;
  if (!srConfig || !srConfig.siteKey) {
    return false;
  }

  registerServiceRadarTrace(win);

  if (normalizeSampleRate(srConfig.sampleRate) <= 0) {
    srConfig.sampledOut = true;
    return false;
  }

  const siteKey = String(srConfig.siteKey).trim();
  if (!siteKey) return false;

  const tracePropagateOrigins = Array.isArray(srConfig.tracePropagateOrigins)
    ? srConfig.tracePropagateOrigins
    : Array.isArray(srConfig.trace_propagate_origins)
      ? srConfig.trace_propagate_origins
      : [];
  const beaconUrl = buildBeaconUrl(srConfig.beaconUrl, siteKey);
  if (!beaconUrl) return false;

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

  initializedBoomerangInstances.add(boomr);
  return true;
}

export function ensureServiceRadarBoomerangInit(win) {
  if (!win || !win.BOOMR) return false;
  if (initServiceRadarBoomerang(win)) return true;

  const srConfig = win.BOOMR_config && win.BOOMR_config.ServiceRadar;
  if (srConfig && srConfig.sampledOut) return false;
  if (pendingLateInitWindows.has(win)) return false;
  pendingLateInitWindows.add(win);

  const doc = win.document;
  let timerId = null;

  const cleanup = () => {
    pendingLateInitWindows.delete(win);
    if (doc && typeof doc.removeEventListener === "function") {
      doc.removeEventListener("DOMContentLoaded", retryInit);
    }
    if (typeof win.removeEventListener === "function") {
      win.removeEventListener("load", retryInit);
    }
    if (timerId !== null && typeof win.clearTimeout === "function") {
      win.clearTimeout(timerId);
      timerId = null;
    }
  };

  function retryInit() {
    if (initServiceRadarBoomerang(win)) {
      cleanup();
      return;
    }
    const cfg = win.BOOMR_config && win.BOOMR_config.ServiceRadar;
    if (cfg && cfg.sampledOut) {
      cleanup();
    }
  }

  if (doc && typeof doc.addEventListener === "function") {
    doc.addEventListener("DOMContentLoaded", retryInit);
  }
  if (typeof win.addEventListener === "function") {
    win.addEventListener("load", retryInit);
  }
  if (doc && doc.readyState === "complete" && typeof win.setTimeout === "function") {
    timerId = win.setTimeout(retryInit, 0);
  }

  return false;
}

if (typeof window !== "undefined" && window.BOOMR) {
  ensureServiceRadarBoomerangInit(window);
}
