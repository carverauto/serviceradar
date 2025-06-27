// src/app/query/page.tsx
import React, { Suspense } from 'react';
import ApiQueryClient from "@/components/Query/APIQueryClient";

// Separate component to handle search params
function QueryPageContent() {
    return (
        <ApiQueryClient query="" />
    );
}

export default function QueryPage() {
    return (
        <div>
            <Suspense fallback={<div className="p-8 text-center">Loading Query Tool...</div>}>
                <QueryPageContent />
            </Suspense>
        </div>
    );
}