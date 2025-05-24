// src/app/query/page.tsx
import React, { Suspense } from 'react';
import ApiQueryClient from "@/components/APIQueryClient";

export const metadata = {
    title: 'API Query Tool - ServiceRadar',
    description: 'Execute queries against the ServiceRadar API.',
};

export default function QueryPage() {
    return (
        <div>
            <Suspense fallback={<div className="p-8 text-center">Loading Query Tool...</div>}>
                <ApiQueryClient />
            </Suspense>
        </div>
    );
}