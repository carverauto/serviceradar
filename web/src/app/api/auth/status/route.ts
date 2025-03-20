// src/app/api/auth-status/route.ts
import { NextResponse } from "next/server";

export async function GET() {
  const authEnabled = process.env.AUTH_ENABLED === "true";

  return NextResponse.json({
    authEnabled: authEnabled,
  });
}
