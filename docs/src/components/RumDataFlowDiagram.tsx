import React, {useState} from 'react';

/**
 * Swiss-grid strata diagram of the ServiceRadar Boomerang RUM ingestion pipeline.
 * Uses the shared `--sr-color-*` and `--sr-font-*` tokens from `src/css/custom.css`
 * with subtle animated flow pulses and a pause-motion toggle.
 */
export default function RumDataFlowDiagram(): React.JSX.Element {
  const [paused, setPaused] = useState(false);

  return (
    <figure className="my-6 rounded-sr-surface border border-sr-line bg-sr-surface p-4 sm:p-5">
      <style>{`
        @keyframes sr-rum-flow {
          from { stroke-dashoffset: 24; }
          to { stroke-dashoffset: 0; }
        }
        .sr-rum-pulse {
          stroke-dasharray: 6 6;
          animation: sr-rum-flow 1.4s linear infinite;
        }
        .sr-rum-pulse-paused {
          stroke-dasharray: 4 4;
          animation: none;
        }
        @media (prefers-reduced-motion: reduce) {
          .sr-rum-pulse {
            animation: none;
          }
        }
      `}</style>

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="font-mono text-[0.7rem] font-semibold uppercase tracking-[0.12em] text-sr-brand">
            Telemetry Pipeline
          </div>
          <div className="mt-0.5 text-base font-semibold text-sr-ink">
            Boomerang RUM Beacon Ingestion &amp; Single-Store Routing
          </div>
          <p className="mt-0.5 mb-0 text-xs text-sr-muted">
            Public browser beacons are key-gated and scrubbed in Rust, published to NATS JetStream,
            and written exclusively to the active telemetry store.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setPaused((p) => !p)}
          className="cursor-pointer rounded-sr-control border border-sr-line bg-sr-control px-2.5 py-1 font-mono text-[0.7rem] text-sr-muted transition-colors hover:border-sr-line-strong hover:text-sr-ink"
        >
          {paused ? 'Resume motion' : 'Pause motion'}
        </button>
      </div>

      <svg
        viewBox="0 0 760 418"
        className="mt-4 block w-full rounded-sr-control border border-sr-line bg-sr-canvas"
        role="img"
        aria-label="Swiss strata architecture diagram showing Browser, Edge, Rust Collector, NATS JetStream, and EventWriter routing to StarRocks or CNPG"
      >
        <defs>
          <marker
            id="sr-rum-arrow"
            viewBox="0 0 10 10"
            refX="8"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 1 2 L 8 5 L 1 8 z" fill="var(--sr-color-brand)" />
          </marker>
          <marker
            id="sr-rum-arrow-muted"
            viewBox="0 0 10 10"
            refX="8"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 1 2 L 8 5 L 1 8 z" fill="var(--sr-color-muted)" />
          </marker>
        </defs>

        {/* Horizontal strata labels & hairline dividers */}
        {[
          {y: 44, div: 82, label: 'BROWSER'},
          {y: 112, div: 146, label: 'EDGE'},
          {y: 196, div: 248, label: 'COLLECTOR'},
          {y: 282, div: 320, label: 'STREAM'},
          {y: 368, div: null, label: 'STORAGE'},
        ].map((row) => (
          <g key={row.label}>
            <text
              x="16"
              y={row.y}
              fill="var(--sr-color-muted)"
              fontSize="10"
              fontWeight="600"
              letterSpacing="0.1em"
              fontFamily="var(--sr-font-mono)"
            >
              {row.label}
            </text>
            {row.div !== null ? (
              <line
                x1="16"
                y1={row.div}
                x2="744"
                y2={row.div}
                stroke="var(--sr-color-line-strong)"
                strokeDasharray="4 4"
                strokeOpacity="0.65"
              />
            ) : null}
          </g>
        ))}

        {/* STRATUM 1: BROWSER */}
        <rect
          x="128"
          y="16"
          width="284"
          height="50"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.25"
        />
        <text
          x="270"
          y="37"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="12.5"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          boomerang-sr.min.js
        </text>
        <text
          x="270"
          y="54"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          CWV (LCP/INP/CLS) · Server-Timing · traceparent
        </text>

        <rect
          x="432"
          y="16"
          width="284"
          height="50"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-line-strong)"
        />
        <text
          x="574"
          y="37"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="12"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          Akamai mPulse (Optional Tee)
        </text>
        <text
          x="574"
          y="54"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          BOOMR.subscribe(&quot;beacon&quot;, sendBeacon)
        </text>

        {/* Flow arrows: Browser -> Edge */}
        <path
          d="M 270 66 L 270 86 L 422 86 L 422 94"
          fill="none"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.5"
          className={paused ? 'sr-rum-pulse-paused' : 'sr-rum-pulse'}
          markerEnd="url(#sr-rum-arrow)"
        />
        <path
          d="M 574 66 L 574 86 L 422 86 L 422 94"
          fill="none"
          stroke="var(--sr-color-muted)"
          strokeWidth="1.25"
          strokeDasharray="4 4"
        />

        {/* STRATUM 2: EDGE */}
        <rect
          x="128"
          y="96"
          width="588"
          height="36"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-line-strong)"
        />
        <text
          x="422"
          y="113"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="12"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          Envoy Gateway HTTPRoute / Akamai CDN
        </text>
        <text
          x="422"
          y="126"
          textAnchor="middle"
          fill="var(--sr-color-brand)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          POST https://rum.example.com/rum/v1/beacon?key=sr_rum_... (OTLP /v1/* stays private)
        </text>

        {/* Flow arrow: Edge -> Collector */}
        <line
          x1="422"
          y1="132"
          x2="422"
          y2="156"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.5"
          className={paused ? 'sr-rum-pulse-paused' : 'sr-rum-pulse'}
          markerEnd="url(#sr-rum-arrow)"
        />

        {/* STRATUM 3: RUST COLLECTOR PIPELINE */}
        <rect
          x="128"
          y="158"
          width="588"
          height="78"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.25"
        />
        <text
          x="144"
          y="177"
          fill="var(--sr-color-ink)"
          fontSize="12"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          Rust Collector Ingress Gate
        </text>
        <text
          x="700"
          y="177"
          textAnchor="end"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          zero CNPG queries on hot path
        </text>

        {[
          {x: 144, title: '1. Key + Origin', sub: 'NATS policy · 64 KiB'},
          {x: 286, title: '2. Rate Limit', sub: 'per-key · /24 /48'},
          {x: 428, title: '3. Scrub & Parse', sub: 'query strip · Server-Timing'},
          {x: 570, title: '4. Enrich & Mask', sub: 'prefix_tags · Geo/ASN'},
        ].map((step) => (
          <g key={step.title}>
            <rect
              x={step.x}
              y="188"
              width="130"
              height="38"
              rx="3"
              fill="var(--sr-color-canvas)"
              stroke="var(--sr-color-line)"
            />
            <text
              x={step.x + 65}
              y="204"
              textAnchor="middle"
              fill="var(--sr-color-ink)"
              fontSize="10"
              fontWeight="600"
              fontFamily="var(--sr-font-sans)"
            >
              {step.title}
            </text>
            <text
              x={step.x + 65}
              y="218"
              textAnchor="middle"
              fill="var(--sr-color-muted)"
              fontSize="8.5"
              fontFamily="var(--sr-font-mono)"
            >
              {step.sub}
            </text>
          </g>
        ))}

        {/* Flow arrows: Collector -> JetStream */}
        <line
          x1="270"
          y1="236"
          x2="270"
          y2="258"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.5"
          className={paused ? 'sr-rum-pulse-paused' : 'sr-rum-pulse'}
          markerEnd="url(#sr-rum-arrow)"
        />
        <line
          x1="574"
          y1="236"
          x2="574"
          y2="258"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.5"
          className={paused ? 'sr-rum-pulse-paused' : 'sr-rum-pulse'}
          markerEnd="url(#sr-rum-arrow)"
        />

        {/* STRATUM 4: NATS JETSTREAM */}
        <rect
          x="128"
          y="260"
          width="284"
          height="46"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-line-strong)"
        />
        <text
          x="270"
          y="279"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="11.5"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          NATS JetStream · rum.beacons.&gt;
        </text>
        <text
          x="270"
          y="295"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          Protobuf RumBeaconV1 (full beacon)
        </text>

        <rect
          x="432"
          y="260"
          width="284"
          height="46"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-line-strong)"
        />
        <text
          x="574"
          y="279"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="11.5"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          NATS JetStream · metrics.rum.&gt;
        </text>
        <text
          x="574"
          y="295"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          MetricBatch (LCP, INP, CLS, Edge/Origin RTT)
        </text>

        {/* Flow arrows: JetStream -> EventWriter -> Active Store */}
        <line
          x1="270"
          y1="306"
          x2="270"
          y2="334"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.5"
          className={paused ? 'sr-rum-pulse-paused' : 'sr-rum-pulse'}
          markerEnd="url(#sr-rum-arrow)"
        />
        <line
          x1="574"
          y1="306"
          x2="574"
          y2="334"
          stroke="var(--sr-color-muted)"
          strokeWidth="1.25"
          strokeDasharray="4 4"
          markerEnd="url(#sr-rum-arrow-muted)"
        />

        {/* STRATUM 5: STORAGE (Single Active Telemetry Store) */}
        <rect
          x="128"
          y="336"
          width="320"
          height="64"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-brand)"
          strokeWidth="1.25"
        />
        <text
          x="288"
          y="356"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="12"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          StarRocks (when enabled)
        </text>
        <text
          x="288"
          y="373"
          textAnchor="middle"
          fill="var(--sr-color-brand)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          rum_beacons + timeseries_metrics
        </text>
        <text
          x="288"
          y="389"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9"
          fontFamily="var(--sr-font-mono)"
        >
          30d daily partitions · EventWriter single-store
        </text>

        <rect
          x="468"
          y="336"
          width="248"
          height="64"
          rx="4"
          fill="var(--sr-color-surface)"
          stroke="var(--sr-color-line-strong)"
        />
        <text
          x="592"
          y="356"
          textAnchor="middle"
          fill="var(--sr-color-ink)"
          fontSize="12"
          fontWeight="600"
          fontFamily="var(--sr-font-sans)"
        >
          CNPG Fallback (no StarRocks)
        </text>
        <text
          x="592"
          y="373"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9.5"
          fontFamily="var(--sr-font-mono)"
        >
          platform.rum_beacons hypertable
        </text>
        <text
          x="592"
          y="389"
          textAnchor="middle"
          fill="var(--sr-color-muted)"
          fontSize="9"
          fontFamily="var(--sr-font-mono)"
        >
          never dual-written · SRQL in:rum
        </text>
      </svg>
    </figure>
  );
}
