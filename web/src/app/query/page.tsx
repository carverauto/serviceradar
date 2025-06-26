'use client';

// src/app/query/page.tsx
import React, { Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import ApiQueryClient from "@/components/Query/APIQueryClient";

export default function QueryPage() {
    const searchParams = useSearchParams();
    const query = searchParams.get('q') || 'show devices';

    return (
        <div>
            <Suspense fallback={<div className="p-8 text-center">Loading Query Tool...</div>}>
                <ApiQueryClient query={query} />
            </Suspense>
        </div>
    );
}