import { NextRequest, NextResponse } from "next/server";
import { proxyConfigRequest } from "@/app/api/admin/config/proxy";

export async function GET(
  req: NextRequest,
  ctx: { params: Promise<{ service: string }> },
): Promise<NextResponse> {
  return proxyConfigRequest("GET", req, ctx);
}

export async function PUT(
  req: NextRequest,
  ctx: { params: Promise<{ service: string }> },
): Promise<NextResponse> {
  return proxyConfigRequest("PUT", req, ctx);
}

export async function DELETE(
  req: NextRequest,
  ctx: { params: Promise<{ service: string }> },
): Promise<NextResponse> {
  return proxyConfigRequest("DELETE", req, ctx);
}
