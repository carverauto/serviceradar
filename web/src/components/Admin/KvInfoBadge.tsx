"use client";

import React, { useEffect, useRef, useState } from 'react';
import { Info } from 'lucide-react';

interface Props {
  kvId?: string;
  compact?: boolean; // compact mode for tiny badges
  hoverTrigger?: boolean; // open on hover instead of click
}

export default function KvInfoBadge({ kvId, compact = true, hoverTrigger = true }: Props) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [data, setData] = useState<{ domain: string; bucket: string } | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function onDocClick(e: MouseEvent) {
      if (!containerRef.current) return;
      if (!containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('click', onDocClick);
    return () => document.removeEventListener('click', onDocClick);
  }, []);

  useEffect(() => {
    if (!open || !kvId || data || loading) return;
    (async () => {
      try {
        setLoading(true);
        setError(null);
        const token = document.cookie
          .split("; ")
          .find((row) => row.startsWith("accessToken="))
          ?.split("=")[1];
        const resp = await fetch(`/api/kv/info?kv_store_id=${encodeURIComponent(kvId)}`, {
          headers: { 'Authorization': `Bearer ${token}` }
        });
        if (!resp.ok) throw new Error('Failed');
        const json = await resp.json();
        setData({ domain: json.domain, bucket: json.bucket });
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unavailable';
        setError(message);
      } finally {
        setLoading(false);
      }
    })();
  }, [open, kvId, data, loading]);

  if (!kvId) return null;

  const eventProps = hoverTrigger ? {
    onMouseEnter: () => setOpen(true),
    onMouseLeave: () => setOpen(false),
  } : {};

  return (
    <div className="relative inline-flex items-center" ref={containerRef} {...eventProps}>
      <span className={`text-[10px] px-1.5 py-0.5 rounded bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200 ${compact ? '' : 'text-xs'}`}>{kvId}</span>
      {!hoverTrigger && (
        <button
          type="button"
          className="ml-1 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
          onClick={(e) => { e.stopPropagation(); setOpen(v => !v); }}
          title="KV Info"
        >
          <Info className="h-3 w-3" />
        </button>
      )}
      {open && (
        <div className="absolute z-20 top-full mt-1 right-0 min-w-[180px] rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-lg p-2 text-xs text-gray-700 dark:text-gray-200">
          <div className="font-medium mb-1">KV Info</div>
          {loading && <div className="opacity-75">Loading…</div>}
          {!loading && error && <div className="text-red-600 dark:text-red-400">{error}</div>}
          {!loading && !error && data && (
            <div className="space-y-1">
              <div><span className="opacity-70">Domain:</span> {data.domain || '-'}</div>
              <div><span className="opacity-70">Bucket:</span> {data.bucket || '-'}</div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
