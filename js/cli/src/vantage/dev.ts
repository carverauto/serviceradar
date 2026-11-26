// `serviceradar vantage dev --fixture <synthetic-clip> [--dir <dir>] [--pipeline <id>] [--exec <cmd>] [--json]`
//
// Executes a local zero-cluster synthetic development loop against a Vantage
// Solution Pack v2 workspace: validates the pack, builds a `VantageFrameContext`,
// runs the local synthetic harness (or `--exec <cmd>`), validates the emitted
// `vantage.result.v1` envelope bounds, and validates observation attributes
// against the pipeline's `signal_schemas/*.schema.json`.

import {execSync} from "node:child_process"
import {existsSync, readFileSync, statSync} from "node:fs"
import {extname, join, resolve} from "node:path"
import {isPlainObject, sha256Hex} from "../pack/canonical.js"
import {validateValueAgainstJsonSchema} from "../pack/json_schema.js"
import {validateVantageProject} from "./validate.js"

const MAX_RESULT_ENVELOPE_BYTES = 960 * 1024
const MAX_OBSERVATIONS_PER_ENVELOPE = 256
const MAX_CROP_JPEG_BYTES = 32 * 1024
const ALLOWED_WORKER_KINDS = new Set(["camera_vlm", "external_rust", "external_python"])
const ALLOWED_SOURCE_MODES = new Set(["recorded_block", "live_keyframe_tap"])

export async function devCommand(options: Record<string, unknown>): Promise<void> {
  const positional = ((options._ as string[] | undefined) || []).filter(Boolean)
  const targetDir = (positional[0] || options.dir || process.cwd()) as string

  if (typeof options.fixture !== "string" || options.fixture.trim() === "") {
    throw new Error(
      "vantage dev requires `--fixture <synthetic-clip>` (no cluster or NATS connection required)",
    )
  }

  const fixturePath = resolve(options.fixture.trim())
  if (!existsSync(fixturePath)) {
    throw new Error(`vantage dev fixture does not exist: "${fixturePath}"`)
  }
  const fixtureStat = statSync(fixturePath)
  if (!fixtureStat.isFile() || fixtureStat.size === 0) {
    throw new Error(`vantage dev fixture must be a non-empty regular file: "${fixturePath}"`)
  }

  const validated = validateVantageProject(targetDir)
  const requestedPipeline =
    typeof options.pipeline === "string" && options.pipeline.trim() !== ""
      ? options.pipeline.trim()
      : null

  const pipeline = requestedPipeline
    ? validated.pipelines.find((p) => p.pipeline_id === requestedPipeline)
    : validated.pipelines[0]

  if (!pipeline) {
    throw new Error(
      requestedPipeline
        ? `pipeline "${requestedPipeline}" not found in "${validated.resolvedDir}"`
        : `no vantage_pipelines found in "${validated.resolvedDir}"`,
    )
  }

  const pipelineId = String(pipeline.pipeline_id)
  const pipelineVersion = String(pipeline.version || "1.0.0")
  const schemaId = String(pipeline.signal_schema_id)
  const schemaVersion = String(pipeline.signal_schema_version || "1.0.0")
  const displayContractId = String(pipeline.display_contract_id || schemaId)
  const signalSchema = validated.signalSchemas.get(schemaId)
  if (!signalSchema) {
    throw new Error(`signal schema "${schemaId}" not found for pipeline "${pipelineId}"`)
  }

  const fixtureBytes = readFileSync(fixturePath)
  const fixtureExt = extname(fixturePath).toLowerCase()
  const fixtureSha = sha256Hex(fixtureBytes)

  let parsedFixture: Record<string, unknown> | null = null
  if (fixtureExt === ".json") {
    let rawJson: unknown
    try {
      rawJson = JSON.parse(fixtureBytes.toString("utf8"))
    } catch (err: any) {
      throw new Error(`invalid JSON fixture "${fixturePath}": ${err?.message || String(err)}`)
    }
    if (!isPlainObject(rawJson)) {
      throw new Error(`JSON fixture "${fixturePath}" root must be a JSON object`)
    }
    parsedFixture = rawJson
  }

  const frameContext = buildVantageFrameContext(
    validated.resolvedDir,
    pipeline,
    fixturePath,
    fixtureSha,
    fixtureBytes.length,
    parsedFixture,
  )

  const workerKind =
    validated.workerKind === "python-worker"
      ? "external_python"
      : validated.workerKind === "rust-worker"
        ? "external_rust"
        : "camera_vlm"

  let resultEnvelope: Record<string, unknown>
  if (typeof options.exec === "string" && options.exec.trim() !== "") {
    resultEnvelope = executeExternalHarness(
      options.exec.trim(),
      validated.resolvedDir,
      fixturePath,
      pipelineId,
      frameContext,
    )
  } else {
    resultEnvelope = runLocalSyntheticHarness({
      packId: String(validated.manifest.id),
      pipelineId,
      pipelineVersion,
      workerKind,
      capability:
        typeof pipeline.capability === "string" && pipeline.capability
          ? pipeline.capability
          : "vantage.vlm.v1",
      schemaId,
      schemaVersion,
      displayContractId,
      frameContext,
      parsedFixture,
      projectDir: validated.resolvedDir,
      signalSchema,
    })
  }

  await validateVantageResultEnvelope(resultEnvelope, signalSchema)

  const observations = resultEnvelope.observations as Array<Record<string, unknown>>
  const summary = {
    status: "ok",
    valid: true,
    requires_cluster: false,
    path: validated.resolvedDir,
    fixture: fixturePath,
    fixture_sha256: fixtureSha,
    pipeline_id: pipelineId,
    signal_schema_id: schemaId,
    worker_kind: resultEnvelope.worker_kind,
    observation_count: observations.length,
    envelope: resultEnvelope,
    observations,
  }

  if (options.json) {
    console.log(JSON.stringify(summary, null, 2))
    return
  }

  console.log(
    `Vantage dev OK (no cluster required): ${pipelineId} processed ${fixturePath} -> ${observations.length} valid observation${observations.length === 1 ? "" : "s"}`,
  )
}

function buildVantageFrameContext(
  projectDir: string,
  pipeline: Record<string, unknown>,
  fixturePath: string,
  fixtureSha: string,
  fixtureBytesLength: number,
  parsedFixture: Record<string, unknown> | null,
): Record<string, unknown> {
  const defaultDetections = [
    {
      track_id: "track-1",
      category: "vehicle",
      confidence: 0.91,
      bbox: [0.28, 0.42, 0.62, 0.84],
    },
  ]

  return {
    schema_version: "vantage.frame.v1",
    source_mode:
      typeof parsedFixture?.source_mode === "string"
        ? parsedFixture.source_mode
        : String(pipeline.source_mode || "recorded_block"),
    camera_source_id:
      typeof parsedFixture?.camera_source_id === "string"
        ? parsedFixture.camera_source_id
        : "00000000-0000-4000-8000-000000000101",
    stream_profile_id:
      typeof parsedFixture?.stream_profile_id === "string"
        ? parsedFixture.stream_profile_id
        : "00000000-0000-4000-8000-000000000102",
    catalog_entry_id:
      parsedFixture?.catalog_entry_id === null
        ? null
        : typeof parsedFixture?.catalog_entry_id === "string"
          ? parsedFixture.catalog_entry_id
          : "00000000-0000-4000-8000-000000000103",
    camera_name:
      typeof parsedFixture?.camera_name === "string" ? parsedFixture.camera_name : "Gate West 01",
    camera_ip: typeof parsedFixture?.camera_ip === "string" ? parsedFixture.camera_ip : "192.0.2.10",
    fragment_sequence:
      typeof parsedFixture?.fragment_sequence === "number" ? parsedFixture.fragment_sequence : 1,
    frame_sequence:
      typeof parsedFixture?.frame_sequence === "number" ? parsedFixture.frame_sequence : 1,
    media_pts_ns:
      typeof parsedFixture?.media_pts_ns === "number" ? parsedFixture.media_pts_ns : 1_000_000_000,
    timeline_ts_us:
      typeof parsedFixture?.timeline_ts_us === "number"
        ? parsedFixture.timeline_ts_us
        : 1_700_000_000_000_000,
    time_basis:
      typeof parsedFixture?.time_basis === "string" ? parsedFixture.time_basis : "received",
    fixture_path: fixturePath,
    fixture_sha256: fixtureSha,
    fixture_bytes: fixtureBytesLength,
    project_dir: projectDir,
    upstream_detections: Array.isArray(parsedFixture?.upstream_detections)
      ? parsedFixture.upstream_detections
      : defaultDetections,
    pipeline_config: pipeline,
  }
}

function executeExternalHarness(
  cmd: string,
  projectDir: string,
  fixturePath: string,
  pipelineId: string,
  frameContext: Record<string, unknown>,
): Record<string, unknown> {
  const stdout = execSync(cmd, {
    cwd: projectDir,
    input: JSON.stringify(frameContext),
    encoding: "utf8",
    env: {
      ...process.env,
      VANTAGE_FIXTURE_PATH: fixturePath,
      VANTAGE_PIPELINE_ID: pipelineId,
    },
  })
  const parsed = JSON.parse(stdout)
  if (!isPlainObject(parsed)) {
    throw new Error("--exec harness must output a JSON VantageResultEnvelope object")
  }
  return parsed
}

function runLocalSyntheticHarness(params: {
  packId: string
  pipelineId: string
  pipelineVersion: string
  workerKind: string
  capability: string
  schemaId: string
  schemaVersion: string
  displayContractId: string
  frameContext: Record<string, unknown>
  parsedFixture: Record<string, unknown> | null
  projectDir: string
  signalSchema: Record<string, unknown>
}): Record<string, unknown> {
  const {parsedFixture, frameContext, projectDir, schemaId, schemaVersion, displayContractId} =
    params

  if (parsedFixture && parsedFixture.schema_version === "vantage.result.v1") {
    return parsedFixture
  }
  if (parsedFixture && isPlainObject(parsedFixture.result)) {
    return parsedFixture.result
  }

  let observations: unknown[] | null = null
  if (parsedFixture && Array.isArray(parsedFixture.observations)) {
    observations = parsedFixture.observations
  } else if (parsedFixture && Array.isArray(parsedFixture.expected_observations)) {
    observations = parsedFixture.expected_observations
  } else if (parsedFixture && isPlainObject(parsedFixture.attributes)) {
    observations = [
      {
        observation_key: `obs-dev-${String(frameContext.fixture_sha256).slice(0, 12)}`,
        fragment_sequence: frameContext.fragment_sequence,
        frame_sequence: frameContext.frame_sequence,
        media_pts_ns: frameContext.media_pts_ns,
        timeline_ts_us: frameContext.timeline_ts_us,
        time_basis: frameContext.time_basis,
        track_id: "track-1",
        category: "license_plate",
        label: String(parsedFixture.attributes.plate_text || "SR-0100"),
        confidence: 0.94,
        bbox: [0.32, 0.58, 0.48, 0.66],
        attributes: parsedFixture.attributes,
        signal_schema_id: schemaId,
        signal_schema_version: schemaVersion,
        display_contract_id: displayContractId,
        search_text: "SR-0100 Gate West 01 license_plate",
      },
    ]
  } else {
    const projectSamplePath = join(projectDir, "fixtures/synthetic_frame.json")
    if (existsSync(projectSamplePath)) {
      try {
        const sampleDoc = JSON.parse(readFileSync(projectSamplePath, "utf8"))
        if (isPlainObject(sampleDoc) && Array.isArray(sampleDoc.expected_observations)) {
          observations = sampleDoc.expected_observations
        }
      } catch {
        // Ignore malformed sample and fall through to schema-driven synthesis.
      }
    }
  }

  if (!observations) {
    observations = [
      {
        observation_key: `obs-dev-${String(frameContext.fixture_sha256).slice(0, 12)}`,
        fragment_sequence: frameContext.fragment_sequence,
        frame_sequence: frameContext.frame_sequence,
        media_pts_ns: frameContext.media_pts_ns,
        timeline_ts_us: frameContext.timeline_ts_us,
        time_basis: frameContext.time_basis,
        track_id: "track-1",
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.94,
        bbox: [0.32, 0.58, 0.48, 0.66],
        attributes: synthesizeAttributesFromSchema(params.signalSchema),
        signal_schema_id: schemaId,
        signal_schema_version: schemaVersion,
        display_contract_id: displayContractId,
        search_text: "SR-0100 Gate West 01 license_plate",
      },
    ]
  }

  return {
    schema_version: "vantage.result.v1",
    job_id: "00000000-0000-4000-8000-000000000199",
    pack_id: params.packId,
    pipeline_id: params.pipelineId,
    pipeline_version: params.pipelineVersion,
    worker_kind: params.workerKind,
    worker_id: "vantage-local-dev-1",
    model_id: "synthetic-dev-harness",
    model_version: "1.0.0",
    capability: params.capability,
    source_mode: frameContext.source_mode,
    camera_source_id: frameContext.camera_source_id,
    stream_profile_id: frameContext.stream_profile_id,
    catalog_entry_id: frameContext.catalog_entry_id,
    descriptor_sha256: frameContext.fixture_sha256,
    observations,
  }
}

function synthesizeAttributesFromSchema(schema: Record<string, unknown>): Record<string, unknown> {
  const props = isPlainObject(schema.properties) ? schema.properties : {}
  const required = Array.isArray(schema.required) ? new Set(schema.required.map(String)) : new Set<string>()
  const out: Record<string, unknown> = {}

  for (const [key, propRaw] of Object.entries(props)) {
    if (!required.has(key) && key !== "plate_text" && key !== "region" && key !== "confidence") {
      continue
    }
    if (!isPlainObject(propRaw)) continue
    if (key === "plate_text") {
      out[key] = "SR-0100"
    } else if (key === "region") {
      out[key] = "US-CA"
    } else if (key === "camera_label") {
      out[key] = "Gate West 01"
    } else if (key === "confidence") {
      out[key] = 0.94
    } else if (propRaw.type === "string") {
      out[key] = "SR-0100"
    } else if (propRaw.type === "number" || propRaw.type === "integer") {
      out[key] = typeof propRaw.minimum === "number" ? propRaw.minimum : 1
    } else if (propRaw.type === "boolean") {
      out[key] = true
    } else if (propRaw.type === "array") {
      out[key] = []
    } else if (propRaw.type === "object") {
      out[key] = {}
    }
  }
  return out
}

async function validateVantageResultEnvelope(
  envelope: Record<string, unknown>,
  signalSchema: Record<string, unknown>,
): Promise<void> {
  const encodedBytes = Buffer.byteLength(JSON.stringify(envelope), "utf8")
  if (encodedBytes > MAX_RESULT_ENVELOPE_BYTES) {
    throw new Error(
      `VantageResultEnvelope size ${encodedBytes} exceeds ${MAX_RESULT_ENVELOPE_BYTES} bytes (960 KiB)`,
    )
  }

  if (envelope.schema_version !== "vantage.result.v1") {
    throw new Error(
      `expected VantageResultEnvelope schema_version "vantage.result.v1", got ${JSON.stringify(envelope.schema_version)}`,
    )
  }

  if (typeof envelope.worker_kind !== "string" || !ALLOWED_WORKER_KINDS.has(envelope.worker_kind)) {
    throw new Error(`invalid worker_kind ${JSON.stringify(envelope.worker_kind)}`)
  }

  if (typeof envelope.source_mode !== "string" || !ALLOWED_SOURCE_MODES.has(envelope.source_mode)) {
    throw new Error(`invalid source_mode ${JSON.stringify(envelope.source_mode)}`)
  }

  if (!Array.isArray(envelope.observations) || envelope.observations.length === 0) {
    throw new Error("VantageResultEnvelope.observations must be a non-empty array")
  }
  if (envelope.observations.length > MAX_OBSERVATIONS_PER_ENVELOPE) {
    throw new Error(
      `VantageResultEnvelope.observations count ${envelope.observations.length} exceeds ${MAX_OBSERVATIONS_PER_ENVELOPE}`,
    )
  }

  const ajvValidator = await loadLazyAjvValidator(signalSchema)

  for (let i = 0; i < envelope.observations.length; i += 1) {
    const obs = envelope.observations[i]
    if (!isPlainObject(obs)) {
      throw new Error(`observations[${i}] must be a JSON object`)
    }
    for (const reqStr of ["observation_key", "category", "label"] as const) {
      if (typeof obs[reqStr] !== "string" || (obs[reqStr] as string).trim() === "") {
        throw new Error(`observations[${i}].${reqStr} must be a non-empty string`)
      }
    }
    if (
      typeof obs.confidence !== "number" ||
      !Number.isFinite(obs.confidence) ||
      obs.confidence < 0 ||
      obs.confidence > 1
    ) {
      throw new Error(`observations[${i}].confidence must be a finite number in [0, 1]`)
    }
    if (obs.bbox !== undefined && obs.bbox !== null) {
      if (
        !Array.isArray(obs.bbox) ||
        obs.bbox.length !== 4 ||
        obs.bbox.some((v) => typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1)
      ) {
        throw new Error(`observations[${i}].bbox must be [x1, y1, x2, y2] with values in [0, 1]`)
      }
      const [x1, y1, x2, y2] = obs.bbox as number[]
      if (!(x1 < x2 && y1 < y2)) {
        throw new Error(`observations[${i}].bbox must satisfy x1 < x2 and y1 < y2`)
      }
    }
    if (obs.crop_jpeg_b64 !== undefined && obs.crop_jpeg_b64 !== null) {
      if (typeof obs.crop_jpeg_b64 !== "string") {
        throw new Error(`observations[${i}].crop_jpeg_b64 must be a base64 string`)
      }
      const decoded = Buffer.from(obs.crop_jpeg_b64, "base64")
      if (decoded.length > MAX_CROP_JPEG_BYTES) {
        throw new Error(
          `observations[${i}].crop_jpeg_b64 decoded size ${decoded.length} exceeds ${MAX_CROP_JPEG_BYTES} bytes (32 KiB)`,
        )
      }
    }

    if (!isPlainObject(obs.attributes)) {
      throw new Error(`observations[${i}].attributes must be a JSON object`)
    }

    if (ajvValidator) {
      if (!ajvValidator(obs.attributes)) {
        const msgs = (ajvValidator.errors || []).map(
          (e: any) => `${e.instancePath || "$"} ${e.message || "schema violation"}`,
        )
        throw new Error(
          `observations[${i}].attributes failed signal_schema validation: ${msgs.join("; ")}`,
        )
      }
    } else {
      const fallbackErrs = validateValueAgainstJsonSchema(obs.attributes, signalSchema)
      if (fallbackErrs.length > 0) {
        throw new Error(
          `observations[${i}].attributes failed signal_schema validation: ${fallbackErrs.join("; ")}`,
        )
      }
    }
  }
}

async function loadLazyAjvValidator(
  schema: Record<string, unknown>,
): Promise<(((val: unknown) => boolean) & {errors?: unknown[] | null}) | null> {
  try {
    const {default: Ajv2020} = await import("ajv/dist/2020.js")
    const ajv = new Ajv2020({allErrors: true, strict: false})
    return ajv.compile(schema) as ((val: unknown) => boolean) & {errors?: unknown[] | null}
  } catch {
    return null
  }
}
