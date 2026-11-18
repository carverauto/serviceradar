// Strict SVG allowlist validator matching `ServiceRadar.Catalog.SvgSanitizer`
// (`openspec/changes/add-solution-packs-and-git-catalog/design.md` Decision 1).
//
// Allowed elements:
//   <svg>, <defs>, <linearGradient>, <radialGradient>, <stop>, <rect>,
//   <circle>, <ellipse>, <line>, <polyline>, <polygon>, <path>, <g>
//
// Rejects <script>, <foreignObject>, <!ENTITY / <!DOCTYPE, event handler
// attributes (`on*`), javascript:/data: attribute URIs, and external
// href / xlink:href / url(...) references.

import type {PackValidationIssue} from "./canonical.js"

const ALLOWED_SVG_ELEMENTS: Set<string> = new Set([
  "svg",
  "defs",
  "linearGradient",
  "radialGradient",
  "stop",
  "rect",
  "circle",
  "ellipse",
  "line",
  "polyline",
  "polygon",
  "path",
  "g",
])

const DATA_URI_BASE64_PREFIX = "data:image/svg+xml;base64,"
const DATA_URI_UTF8_PREFIX = "data:image/svg+xml;utf8,"
const DATA_URI_PLAIN_PREFIX = "data:image/svg+xml,"

export function validateSvgContent(
  rawInput: string,
  file: string,
  path: string,
  options: {allowDataUri?: boolean} = {},
): PackValidationIssue[] {
  const issues: PackValidationIssue[] = []
  const trimmed = rawInput.trim()
  if (!trimmed) {
    issues.push({
      file,
      path,
      code: "empty_svg",
      message: "SVG content must be non-empty",
    })
    return issues
  }

  let xml = trimmed
  if (trimmed.startsWith("data:")) {
    if (!options.allowDataUri) {
      issues.push({
        file,
        path,
        code: "invalid_svg_file",
        message: "SVG asset files must contain raw <svg> XML, not a data: URI",
      })
      return issues
    }
    const decoded = decodeSvgDataUri(trimmed)
    if (!decoded.ok) {
      issues.push({
        file,
        path,
        code: "invalid_svg_data_uri",
        message: decoded.error,
      })
      return issues
    }
    xml = decoded.xml.trim()
  }

  // Strip benign XML declaration and XML comments after checking for forbidden DTDs.
  if (/<!DOCTYPE\b/i.test(xml) || /<!ENTITY\b/i.test(xml)) {
    issues.push({
      file,
      path,
      code: "forbidden_svg_dtd",
      message: "SVG must not contain <!DOCTYPE> or <!ENTITY> declarations",
    })
    return issues
  }

  if (/<\?(?!xml\b)/i.test(xml)) {
    issues.push({
      file,
      path,
      code: "forbidden_svg_pi",
      message: "SVG must not contain processing instructions other than <?xml ...?>",
    })
    return issues
  }

  const withoutXmlDecl = xml
    .replace(/^\s*<\?xml\b[^?]*\?>\s*/i, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .trim()

  if (!/^<svg(?:\s|>|\/)/i.test(withoutXmlDecl)) {
    issues.push({
      file,
      path,
      code: "missing_svg_root",
      message: "SVG must start with a root <svg> element",
    })
    return issues
  }

  const tagRegex = /<\/?([A-Za-z_][A-Za-z0-9:._-]*)([^<>]*?)\/?>/g
  let match: RegExpExecArray | null
  let sawSvgElement = false

  while ((match = tagRegex.exec(withoutXmlDecl)) !== null) {
    const fullMatch = match[0]
    const rawTagName = match[1]
    const attrText = match[2] || ""
    const isClosing = fullMatch.startsWith("</")

    // Strip optional `svg:` namespace prefix only if explicitly used, otherwise exact match.
    const localName = rawTagName.startsWith("svg:") ? rawTagName.slice(4) : rawTagName
    if (!ALLOWED_SVG_ELEMENTS.has(localName)) {
      issues.push({
        file,
        path,
        code: "forbidden_svg_element",
        message: `SVG element <${rawTagName}> is not in the Solution Pack allowlist`,
      })
      continue
    }

    if (localName === "svg") {
      sawSvgElement = true
    }

    if (!isClosing && attrText.trim() !== "") {
      validateSvgAttributes(attrText, rawTagName, file, path, issues)
    }
  }

  if (!sawSvgElement) {
    issues.push({
      file,
      path,
      code: "missing_svg_root",
      message: "SVG contains no valid <svg> element",
    })
  }

  return issues
}

function decodeSvgDataUri(
  uri: string,
): {ok: true; xml: string; error?: undefined} | {ok: false; error: string; xml?: undefined} {
  if (uri.startsWith(DATA_URI_BASE64_PREFIX)) {
    const b64 = uri.slice(DATA_URI_BASE64_PREFIX.length).trim()
    if (!b64 || !/^[A-Za-z0-9+/]+={0,2}$/.test(b64) || b64.length % 4 !== 0) {
      return {ok: false, error: "icon data:image/svg+xml;base64 URI has invalid base64 payload"}
    }
    const xml = Buffer.from(b64, "base64").toString("utf8")
    return {ok: true, xml}
  }
  if (uri.startsWith(DATA_URI_UTF8_PREFIX)) {
    try {
      return {ok: true, xml: decodeURIComponent(uri.slice(DATA_URI_UTF8_PREFIX.length))}
    } catch {
      return {ok: false, error: "icon data:image/svg+xml;utf8 URI could not be URI-decoded"}
    }
  }
  if (uri.startsWith(DATA_URI_PLAIN_PREFIX)) {
    try {
      return {ok: true, xml: decodeURIComponent(uri.slice(DATA_URI_PLAIN_PREFIX.length))}
    } catch {
      return {ok: false, error: "icon data:image/svg+xml URI could not be URI-decoded"}
    }
  }
  return {
    ok: false,
    error: "icon data URI must use data:image/svg+xml;base64,... or inline <svg> markup",
  }
}

function validateSvgAttributes(
  attrText: string,
  tagName: string,
  file: string,
  path: string,
  issues: PackValidationIssue[],
): void {
  const attrRegex = /([A-Za-z_:][A-Za-z0-9:._-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g
  let match: RegExpExecArray | null

  while ((match = attrRegex.exec(attrText)) !== null) {
    const attrName = match[1]
    const lowerAttr = attrName.toLowerCase()
    const attrVal = (match[2] ?? match[3] ?? match[4] ?? "").trim()

    if (lowerAttr.startsWith("on")) {
      issues.push({
        file,
        path,
        code: "forbidden_svg_event_handler",
        message: `SVG <${tagName}> contains forbidden event handler attribute "${attrName}"`,
      })
      continue
    }

    const decodedVal = decodeHtmlEntitiesMinimal(attrVal).trim()
    if (/^(?:javascript|vbscript|data)\s*:/i.test(decodedVal)) {
      issues.push({
        file,
        path,
        code: "forbidden_svg_uri",
        message: `SVG <${tagName}> attribute "${attrName}" contains a forbidden URI scheme`,
      })
      continue
    }

    if (lowerAttr === "href" || lowerAttr === "xlink:href") {
      if (decodedVal !== "" && !decodedVal.startsWith("#")) {
        issues.push({
          file,
          path,
          code: "forbidden_svg_external_href",
          message: `SVG <${tagName}> attribute "${attrName}" may only reference internal "#id" fragments, got "${attrVal}"`,
        })
      }
      continue
    }

    if (/url\(\s*['"]?(?!#)/i.test(decodedVal)) {
      issues.push({
        file,
        path,
        code: "forbidden_svg_external_url_ref",
        message: `SVG <${tagName}> attribute "${attrName}" contains an external url(...) reference`,
      })
    }
  }
}

function decodeHtmlEntitiesMinimal(input: string): string {
  return input
    .replace(/&#x([0-9a-f]+);?/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16) || 0))
    .replace(/&#([0-9]+);?/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10) || 0))
    .replace(/&colon;/gi, ":")
    .replace(/&tab;/gi, "\t")
    .replace(/&newline;/gi, "\n")
}
