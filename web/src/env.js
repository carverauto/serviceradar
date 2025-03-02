// src/env.js
import { createRuntimeEnv } from 'next-runtime-env';

// Create environment with server runtime variables
export const env = createRuntimeEnv({
  // List the server-only variables you need access to
  serverOnly: ['API_KEY'],
  
  // Optional: List any client-side variables
  clientSide: ['NEXT_PUBLIC_BACKEND_URL', 'NEXT_PUBLIC_API_URL']
});
