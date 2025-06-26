'use client';

// src/app/query/page.tsx
import React, { Suspense } from 'react';
import ApiQueryClient from "@/components/Query/APIQueryClient";

export default function QueryPage() {
    return (
        <div>
            <Suspense fallback={<div className="p-8 text-center">Loading Query Tool...</div>}>
                <ApiQueryClient />
            </Suspense>
        </div>
    );
}