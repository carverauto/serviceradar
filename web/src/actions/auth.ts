// src/actions/auth.ts
'use server';

import { env } from 'next-runtime-env';

export async function getAuthEnabled() {
    const authEnabled = env('AUTH_ENABLED') === 'true';
    return { authEnabled };
}
