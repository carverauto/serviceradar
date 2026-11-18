const TRACEPARENT_HEADER = "traceparent";
const DEFAULT_BEACON_PATH = "/rum/v1/beacon";
const PATCHED_MARKER = "__srTracePatched";

function toHex(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 1) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

function randomBytes(length, cryptoObj) {
  const bytes = new Uint8Array(length);
  if (cryptoObj && typeof cryptoObj.getRandomValues === "function") {
    cryptoObj.getRandomValues(bytes);
  } else {
    for (let i = 0; i < length; i += 1) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }

  let nonZero = false;
  for (let i = 0; i < length; i += 1) {
    if (bytes[i] !== 0) {
      nonZero = true;
      break;
    }
  }
  if (!nonZero) {
    bytes[length - 1] = 1;
  }
  return bytes;
}

export function generateTraceparent(cryptoObj) {
  const traceId = toHex(randomBytes(16, cryptoObj));
  const spanId = toHex(randomBytes(8, cryptoObj));
  return {
    traceId,
    spanId,
    traceparent: `00-${traceId}-${spanId}-01`,
  };
}

export function normalizeOrigin(raw, baseOrigin) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;

  try {
    const parsed = baseOrigin ? new URL(trimmed, baseOrigin) : new URL(trimmed);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    if (!parsed.origin || parsed.origin === "null") return null;
    return parsed.origin.toLowerCase();
  } catch (_err) {
    return null;
  }
}

export function normalizeAllowedOrigins(origins, pageOrigin) {
  const allowed = new Set();
  const normalizedPageOrigin = normalizeOrigin(pageOrigin);
  if (normalizedPageOrigin) {
    allowed.add(normalizedPageOrigin);
  }

  if (Array.isArray(origins)) {
    for (let i = 0; i < origins.length; i += 1) {
      const normalized = normalizeOrigin(origins[i], pageOrigin);
      if (normalized) {
        allowed.add(normalized);
      }
    }
  }

  return allowed;
}

export function isBeaconTarget(targetUrl, pageOrigin, beaconUrl = DEFAULT_BEACON_PATH) {
  if (!targetUrl) return false;
  const base = normalizeOrigin(pageOrigin) || "http://localhost";
  try {
    const target = new URL(String(targetUrl), base);
    const beacon = new URL(String(beaconUrl || DEFAULT_BEACON_PATH), base);
    return (
      target.origin.toLowerCase() === beacon.origin.toLowerCase() &&
      target.pathname === beacon.pathname
    );
  } catch (_err) {
    return false;
  }
}

export function shouldPropagateTrace(
  targetUrl,
  pageOrigin,
  allowedOrigins = [],
  beaconUrl = DEFAULT_BEACON_PATH,
) {
  if (!targetUrl) return false;
  const normalizedPageOrigin = normalizeOrigin(pageOrigin);
  if (!normalizedPageOrigin) return false;

  let parsed;
  try {
    parsed = new URL(String(targetUrl), normalizedPageOrigin);
  } catch (_err) {
    return false;
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return false;
  }

  if (isBeaconTarget(parsed.href, normalizedPageOrigin, beaconUrl)) {
    return false;
  }

  const targetOrigin = parsed.origin.toLowerCase();
  if (targetOrigin === normalizedPageOrigin) {
    return true;
  }

  const allowed = normalizeAllowedOrigins(allowedOrigins, normalizedPageOrigin);
  return allowed.has(targetOrigin);
}

export function hasHeader(headers, headerName) {
  if (!headers) return false;
  const needle = String(headerName).toLowerCase();

  if (typeof headers.has === "function") {
    return headers.has(needle) || headers.has(headerName);
  }

  if (Array.isArray(headers)) {
    return headers.some(
      (entry) => Array.isArray(entry) && String(entry[0] || "").toLowerCase() === needle,
    );
  }

  if (typeof headers === "object") {
    return Object.keys(headers).some((key) => String(key).toLowerCase() === needle);
  }

  return false;
}

function withHeaderInit(init, headerName, value, win) {
  const nextInit = init ? { ...init } : {};
  const existing = nextInit.headers;

  if (win && typeof win.Headers === "function" && existing instanceof win.Headers) {
    const cloned = new win.Headers(existing);
    cloned.set(headerName, value);
    nextInit.headers = cloned;
    return nextInit;
  }

  if (Array.isArray(existing)) {
    nextInit.headers = [...existing, [headerName, value]];
    return nextInit;
  }

  nextInit.headers = {
    ...(existing && typeof existing === "object" ? existing : {}),
    [headerName]: value,
  };
  return nextInit;
}

function recordTraceContext(win, state, trace) {
  state.lastTrace = trace;
  if (win && win.BOOMR && typeof win.BOOMR.addVar === "function") {
    win.BOOMR.addVar(
      {
        "sr.trace_id": trace.traceId,
        "sr.span_id": trace.spanId,
      },
      true,
    );
  }
}

export function patchFetch(win, state) {
  if (!win || typeof win.fetch !== "function") return;
  if (win.fetch[PATCHED_MARKER]) return;

  const originalFetch = win.fetch;
  const wrappedFetch = function serviceradarTracedFetch(input, init) {
    try {
      const targetUrl =
        typeof input === "string"
          ? input
          : input && typeof input.url === "string"
            ? input.url
            : input &&
                ((typeof win.URL === "function" && input instanceof win.URL) ||
                  (typeof URL === "function" && input instanceof URL))
              ? input.href
              : "";

      const pageOrigin = win.location && win.location.origin;
      if (
        shouldPropagateTrace(
          targetUrl,
          pageOrigin,
          state.tracePropagateOrigins,
          state.beaconUrl,
        )
      ) {
        const requestHasTraceparent =
          (input && typeof input === "object" && hasHeader(input.headers, TRACEPARENT_HEADER)) ||
          hasHeader(init && init.headers, TRACEPARENT_HEADER);

        if (!requestHasTraceparent) {
          const trace = generateTraceparent(win.crypto);
          recordTraceContext(win, state, trace);

          if (
            typeof win.Request === "function" &&
            input instanceof win.Request &&
            typeof win.Headers === "function"
          ) {
            const headers = new win.Headers((init && init.headers) || input.headers);
            headers.set(TRACEPARENT_HEADER, trace.traceparent);
            const nextRequest = new win.Request(input, { ...(init || {}), headers });
            return originalFetch.call(this, nextRequest);
          }

          const nextInit = withHeaderInit(init, TRACEPARENT_HEADER, trace.traceparent, win);
          return originalFetch.call(this, input, nextInit);
        }
      }
    } catch (_err) {
      // Never break application network calls if trace instrumentation fails.
    }

    return originalFetch.call(this, input, init);
  };

  wrappedFetch[PATCHED_MARKER] = true;
  win.fetch = wrappedFetch;
}

export function patchXMLHttpRequest(win, state) {
  if (!win || typeof win.XMLHttpRequest !== "function" || !win.XMLHttpRequest.prototype) return;
  const proto = win.XMLHttpRequest.prototype;
  if (proto[PATCHED_MARKER]) return;

  const originalOpen = proto.open;
  const originalSetRequestHeader = proto.setRequestHeader;
  const originalSend = proto.send;

  proto.open = function serviceradarTracedOpen(method, url) {
    this.__srTraceMeta = {
      method: method ? String(method) : "GET",
      url: url ? String(url) : "",
      explicitTraceparent: false,
    };
    return originalOpen.apply(this, arguments);
  };

  proto.setRequestHeader = function serviceradarTracedSetRequestHeader(name, _value) {
    if (this.__srTraceMeta && String(name || "").toLowerCase() === TRACEPARENT_HEADER) {
      this.__srTraceMeta.explicitTraceparent = true;
    }
    return originalSetRequestHeader.apply(this, arguments);
  };

  proto.send = function serviceradarTracedSend() {
    try {
      const meta = this.__srTraceMeta;
      const pageOrigin = win.location && win.location.origin;
      if (
        meta &&
        !meta.explicitTraceparent &&
        shouldPropagateTrace(
          meta.url,
          pageOrigin,
          state.tracePropagateOrigins,
          state.beaconUrl,
        )
      ) {
        const trace = generateTraceparent(win.crypto);
        recordTraceContext(win, state, trace);
        originalSetRequestHeader.call(this, TRACEPARENT_HEADER, trace.traceparent);
      }
    } catch (_err) {
      // Never break application XHR calls if trace instrumentation fails.
    }
    return originalSend.apply(this, arguments);
  };

  proto[PATCHED_MARKER] = true;
}

function formatNavigationServerTiming(win) {
  try {
    const perf = win && win.performance;
    if (!perf || typeof perf.getEntriesByType !== "function") return "";
    const navEntries = perf.getEntriesByType("navigation");
    const nav = Array.isArray(navEntries) && navEntries.length > 0 ? navEntries[0] : null;
    const timingList = nav && Array.isArray(nav.serverTiming) ? nav.serverTiming : [];
    if (timingList.length === 0) return "";

    return timingList
      .map((entry) => {
        if (!entry || !entry.name) return "";
        const parts = [String(entry.name)];
        if (typeof entry.duration === "number" && Number.isFinite(entry.duration)) {
          parts.push(`dur=${entry.duration}`);
        }
        if (entry.description) {
          parts.push(`desc="${String(entry.description).replace(/"/g, "")}"`);
        }
        return parts.join(";");
      })
      .filter(Boolean)
      .join(", ");
  } catch (_err) {
    return "";
  }
}

function setSingleBeaconVar(win, vars, state, key, value) {
  vars[key] = value;
  if (state && state.normalizedKeys) {
    state.normalizedKeys.add(key);
  }
  if (win && win.BOOMR && typeof win.BOOMR.addVar === "function") {
    win.BOOMR.addVar(key, value, true);
  }
}

function normalizeBoomerangVarsOnBeacon(vars, win, state) {
  if (!vars || typeof vars !== "object") return;

  if (vars["c.lcp"] == null && vars["pt.lcp"] != null) {
    setSingleBeaconVar(win, vars, state, "c.lcp", vars["pt.lcp"]);
  }
  if (vars["c.fcp"] == null && vars["pt.fcp"] != null) {
    setSingleBeaconVar(win, vars, state, "c.fcp", vars["pt.fcp"]);
  }
  if (vars["c.inp"] == null) {
    if (vars["et.inp"] != null) {
      setSingleBeaconVar(win, vars, state, "c.inp", vars["et.inp"]);
    } else if (vars["et.inp.inc"] != null) {
      setSingleBeaconVar(win, vars, state, "c.inp", vars["et.inp.inc"]);
    }
  }
  if (vars["c.e.rage"] == null && vars["c.c.r"] != null) {
    setSingleBeaconVar(win, vars, state, "c.e.rage", vars["c.c.r"]);
  }
  if (vars["http.status_code"] == null && vars["http.errno"] != null) {
    const numericStatus = Number(vars["http.errno"]);
    if (Number.isFinite(numericStatus) && numericStatus >= 100) {
      setSingleBeaconVar(win, vars, state, "http.status_code", numericStatus);
    }
  }

  const rawServerTiming = vars.servertiming;
  const trimmedServerTiming =
    typeof rawServerTiming === "string" ? rawServerTiming.trim() : "";
  const isBoomerangLookupArray =
    Array.isArray(rawServerTiming) ||
    trimmedServerTiming.startsWith("[") ||
    trimmedServerTiming.startsWith("~(");
  const isInitialNav =
    vars["http.initiator"] == null || vars["http.initiator"] === "spa_hard";
  const hasExplicitSt =
    typeof vars.st === "string" ? vars.st.trim() !== "" : vars.st != null;

  if (isBoomerangLookupArray) {
    if (hasExplicitSt) {
      setSingleBeaconVar(win, vars, state, "servertiming", vars.st);
    } else {
      const navServerTiming = isInitialNav ? formatNavigationServerTiming(win) : "";
      if (navServerTiming) {
        setSingleBeaconVar(win, vars, state, "st", navServerTiming);
        setSingleBeaconVar(win, vars, state, "servertiming", navServerTiming);
      } else {
        delete vars.servertiming;
        if (win && win.BOOMR && typeof win.BOOMR.removeVar === "function") {
          win.BOOMR.removeVar("servertiming");
        }
      }
    }
  } else if (!hasExplicitSt && rawServerTiming == null) {
    const navServerTiming = isInitialNav ? formatNavigationServerTiming(win) : "";
    if (navServerTiming) {
      setSingleBeaconVar(win, vars, state, "st", navServerTiming);
      setSingleBeaconVar(win, vars, state, "servertiming", navServerTiming);
    }
  }
}

export function registerServiceRadarTrace(win) {
  if (!win) return null;
  win.BOOMR = win.BOOMR || {};
  win.BOOMR.plugins = win.BOOMR.plugins || {};

  if (win.BOOMR.plugins.ServiceRadarTrace) {
    return win.BOOMR.plugins.ServiceRadarTrace;
  }

  const state = {
    initialized: false,
    tracePropagateOrigins: [],
    beaconUrl: DEFAULT_BEACON_PATH,
    lastTrace: null,
    subscribedBeacon: false,
    normalizedKeys: new Set(),
  };

  const plugin = {
    init(config) {
      const pluginConfig = (config && config.ServiceRadarTrace) || {};
      const globalConfig = (win.BOOMR_config && win.BOOMR_config.ServiceRadar) || {};

      const origins = Array.isArray(pluginConfig.tracePropagateOrigins)
        ? pluginConfig.tracePropagateOrigins
        : Array.isArray(pluginConfig.trace_propagate_origins)
          ? pluginConfig.trace_propagate_origins
          : Array.isArray(globalConfig.tracePropagateOrigins)
            ? globalConfig.tracePropagateOrigins
            : Array.isArray(globalConfig.trace_propagate_origins)
              ? globalConfig.trace_propagate_origins
              : [];

      state.tracePropagateOrigins = origins;
      state.beaconUrl =
        pluginConfig.beaconUrl ||
        globalConfig.beaconUrl ||
        (config && config.beacon_url) ||
        DEFAULT_BEACON_PATH;

      patchFetch(win, state);
      patchXMLHttpRequest(win, state);

      if (!state.subscribedBeacon && win.BOOMR && typeof win.BOOMR.subscribe === "function") {
        state.subscribedBeacon = true;
        win.BOOMR.subscribe("before_beacon", function onBeforeBeacon(vars) {
          normalizeBoomerangVarsOnBeacon(vars, win, state);
        });
        win.BOOMR.subscribe("beacon", function onBeacon() {
          if (state.normalizedKeys.size > 0 && win.BOOMR && typeof win.BOOMR.removeVar === "function") {
            win.BOOMR.removeVar(Array.from(state.normalizedKeys));
          }
          state.normalizedKeys.clear();
        });
      }

      state.initialized = true;
      return this;
    },
    is_complete() {
      return true;
    },
  };

  win.BOOMR.plugins.ServiceRadarTrace = plugin;
  return plugin;
}

if (typeof window !== "undefined") {
  registerServiceRadarTrace(window);
}
