#!/usr/bin/env bun
import {
  accessSync, constants, existsSync, mkdirSync, readFileSync, readdirSync,
  rmSync, statSync, writeFileSync,
} from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { sampleAcquireDir, sampleBuildDir, sampleCorpusPath, sampleWorksetPath } from "./sample-paths.ts";

type Mode = "raw" | "protect" | "protect-naive";
type Sample = { group: "bench/micro" | "bench/application"; kind: "micro" | "application"; name: string; key: string };
type Task = { sample: Sample; trial: number; mode: Mode };
type Run = Task & {
  status: "success" | "failed"; hostWallNs?: number; hostEcallNs?: number;
  enclaveTicks?: number; iterations?: number; error?: string;
};
type Size = { enclaveBytes: number; ptLoadFileBytes: number | null; ptLoadMemoryBytes: number | null; executablePages: number | null };
type Sizes = Record<Mode, Size>;
type Result = { code: number; stdout: string; stderr: string; error: string };
type Options = { trials: number; seed: number; budget: number | undefined; samples: string[]; mainArgs: string[]; supplemental: boolean; csv: string | undefined; dryRun: boolean };

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const modes: Mode[] = ["raw", "protect", "protect-naive"];
const groups = [
  { group: "bench/micro" as const, kind: "micro" as const },
  { group: "bench/application" as const, kind: "application" as const },
];
const bun = command("bun");
const nix = command("nix");

function command(name: string): string {
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    const candidate = path.join(dir, name);
    try { accessSync(candidate, constants.X_OK); return candidate; } catch {}
  }
  throw new Error("missing command in PATH: " + name);
}

function usage(): string {
  return "usage: bun scripts/measure-bench.ts [--sample GROUP/NAME] [--trials N] [--seed N] [--acquire-budget N] [--main-arg ARG] [--no-supplemental] [--csv FILE] [--dry-run]";
}

function parseArgs(argv: string[]): Options | { help: true } {
  const options = {
    trials: 5, seed: randomBytes(4).readUInt32LE(0) || 1, budget: undefined as number | undefined,
    samples: [] as string[], mainArgs: [] as string[], supplemental: true,
    csv: undefined as string | undefined, dryRun: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") return { help: true as const };
    if (arg === "--dry-run") { options.dryRun = true; continue; }
    if (arg === "--no-supplemental") { options.supplemental = false; continue; }
    if (arg === "--main-arg") {
      const value = argv[++i];
      if (value === undefined) throw new Error("--main-arg requires a value");
      options.mainArgs.push(value);
      continue;
    }
    if (arg === "--sample") {
      const value = argv[++i];
      if (value === undefined || value.startsWith("--")) throw new Error("--sample requires GROUP/NAME");
      options.samples.push(value);
      continue;
    }
    const value = argv[++i];
    if (value === undefined) throw new Error(arg + " requires a value");
    if (arg === "--csv") { options.csv = value; continue; }
    const number = Number(value);
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(number)) throw new Error(arg + " must be an integer");
    if (arg === "--trials" && number >= 1 && number <= 1000) options.trials = number;
    else if (arg === "--seed" && number <= 0xffffffff) options.seed = number || 0x9e3779b9;
    else if (arg === "--acquire-budget" && number >= 1 && number <= 100000) options.budget = number;
    else if (["--trials", "--seed", "--acquire-budget"].includes(arg)) throw new Error(arg + " is outside range");
    else throw new Error("unknown option " + arg);
  }
  return options;
}

function discoverSamples(): Sample[] {
  const samples: Sample[] = [];
  for (const { group, kind } of groups) {
    const dir = path.join(root, group);
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (!entry.isDirectory() || entry.name === "common") continue;
      if (existsSync(path.join(dir, entry.name, "CMakeLists.txt"))) {
        samples.push({ group, kind, name: entry.name, key: group + "/" + entry.name });
      }
    }
  }
  if (!samples.length) throw new Error("no bench sample directories with CMakeLists.txt were found");
  return samples;
}

function supplementalCommands(sample: Sample): string[][] {
  if (sample.group === "bench/application" &&
      ["ehsm", "ehsm-opt-1", "ehsm-opt-2"].includes(sample.name)) {
    return [["--self-test"], ["--compat-check"], ["--sm4-check"]];
  }
  return [["--self-test"]];
}

function run(cmd: string, args: string[], cwd = root, env: Record<string, string | undefined> = process.env, maxBuffer = 64 * 1024 * 1024): Result {
  const result = spawnSync(cmd, args, { cwd, env, encoding: "utf8", maxBuffer });
  return { code: result.status ?? 127, stdout: result.stdout ?? "", stderr: result.stderr ?? "", error: result.error ? String(result.error) : "" };
}

function detail(result: Result): string {
  const text = result.stderr || result.stdout || result.error;
  return text.length > 5000 ? text.slice(-5000) : text;
}

function requireSuccess(label: string, result: Result): void {
  if (result.code !== 0) throw new Error(label + " failed (exit " + result.code + ")\n" + detail(result));
}

function jsonFile(filename: string): Record<string, unknown> {
  const value: unknown = JSON.parse(readFileSync(filename, "utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid JSON object: " + filename);
  return value as Record<string, unknown>;
}

function storeOutput(attr: string, env: Record<string, string | undefined>): string {
  const result = run(nix, ["build", "--no-link", "--print-out-paths", "--no-write-lock-file", attr], root, env);
  requireSuccess("Nix " + attr, result);
  const output = result.stdout.split(/\r?\n/).map((line) => line.trim()).filter((line) => line.startsWith("/nix/store/")).at(-1);
  if (!output || !existsSync(output)) throw new Error("Nix did not return a usable output for " + attr);
  return output;
}

function profileDir(sample: Sample): string {
  return sampleBuildDir(root, sample.group, sample.name, "protect");
}

function buildDir(sample: Sample, mode: Mode): string {
  return sampleBuildDir(root, sample.group, sample.name, mode);
}

function readelfFor(directory: string): string | undefined {
  const cache = path.join(directory, "CMakeCache.txt");
  if (existsSync(cache)) {
    const line = readFileSync(cache, "utf8").split(/\r?\n/).find((item) => item.startsWith("CMAKE_READELF:"));
    const value = line?.slice(line.indexOf("=") + 1).trim();
    if (value && existsSync(value)) return value;
  }
  for (const name of ["llvm-readelf", "readelf"]) {
    try { return command(name); } catch {}
  }
  return undefined;
}

function elfMetrics(image: string, readelf: string | undefined): Pick<Size, "ptLoadFileBytes" | "ptLoadMemoryBytes" | "executablePages"> {
  if (!readelf) return { ptLoadFileBytes: null, ptLoadMemoryBytes: null, executablePages: null };
  const result = run(readelf, ["-lW", image]);
  requireSuccess("readelf " + image, result);
  let fileBytes = 0n, memoryBytes = 0n;
  const ranges: Array<[bigint, bigint]> = [];
  for (const line of result.stdout.split(/\r?\n/)) {
    const fields = line.trim().split(/\s+/);
    if (fields[0] !== "LOAD" || fields.length < 8) continue;
    const hex = (text: string) => /^0x[0-9a-f]+$/i.test(text) ? BigInt(text) : 0n;
    const address = hex(fields[2]!);
    const file = hex(fields[4]!);
    const memory = hex(fields[5]!);
    const flags = fields.slice(6, -1).join("");
    fileBytes += file;
    memoryBytes += memory;
    if (flags.includes("E") && memory) {
      const page = 4096n;
      ranges.push([address / page, (address + memory + page - 1n) / page]);
    }
  }
  if (!fileBytes) throw new Error("readelf found no PT_LOAD segments: " + image);
  ranges.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
  let pages = 0n, start = 0n, end = 0n;
  for (const [nextStart, nextEnd] of ranges) {
    if (!end) { start = nextStart; end = nextEnd; }
    else if (nextStart <= end) end = nextEnd > end ? nextEnd : end;
    else { pages += end - start; start = nextStart; end = nextEnd; }
  }
  if (end) pages += end - start;
  return { ptLoadFileBytes: Number(fileBytes), ptLoadMemoryBytes: Number(memoryBytes), executablePages: Number(pages) };
}

function artifactMetrics(sample: Sample, mode: Mode): Size {
  const dir = buildDir(sample, mode);
  const image = path.join(dir, "enclave.signed.so");
  if (!existsSync(image) || !existsSync(path.join(dir, "host"))) throw new Error("prebuilt outputs missing for " + sample.key + " " + mode);
  return { enclaveBytes: statSync(image).size, ...elfMetrics(image, readelfFor(dir)) };
}

function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return (state >>> 0) / 0x100000000; };
}

function shuffle<T>(items: T[], random: () => number): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [out[i], out[j]] = [out[j]!, out[i]!]; }
  return out;
}

function schedule(samples: Sample[], trials: number, seed: number): Task[] {
  const random = rng(seed), result: Task[] = [];
  for (let trial = 1; trial <= trials; trial++) {
    const orders = new Map(samples.map((sample) => [sample.key, shuffle(modes, random)]));
    for (let position = 0; position < modes.length; position++) {
      for (const sample of shuffle(samples, random)) result.push({ sample, trial, mode: orders.get(sample.key)![position]! });
    }
  }
  return result;
}

function median(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}

export function parseMicro(stdout: string, expectedSample: string): { ticks: number; ns: number; count: number } {
  let header = false;
  const ticks: number[] = [], ns: number[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (line.trim() === "sample,iteration,enclave_tsc_ticks,host_ecall_ns") { header = true; continue; }
    if (!header || !line.trim()) continue;
    const fields = line.trim().split(",");
    if (fields[0] !== expectedSample) {
      if (fields.length === 4 && fields.slice(1).every((field) => /^\d+$/.test(field))) throw new Error("micro host emitted rows for an unexpected sample: " + fields[0]);
      continue; // ignore runner status after the CSV
    }
    if (fields.length !== 4 || !fields.slice(1).every((field) => /^\d+$/.test(field))) throw new Error("micro host emitted a malformed timing row");
    ticks.push(Number(fields[2])); ns.push(Number(fields[3]));
  }
  const t = median(ticks), n = median(ns);
  if (t === null || n === null) throw new Error("micro host emitted no timing rows");
  return { ticks: t, ns: n, count: ticks.length };
}

function buildMode(sample: Sample, mode: Mode, env: Record<string, string | undefined>): Size {
  console.log(sample.key + ": prebuild " + mode);
  requireSuccess(sample.key + " " + mode + " build", run(bun, ["scripts/sample.ts", "build", sample.group, sample.name, mode], root, env));
  return artifactMetrics(sample, mode);
}

const canonicalRuntimeEnvKeys = ["PATH", "LD_LIBRARY_PATH", "SGX_AESM_ADDR", "LANG", "LC_ALL", "TZ"] as const;

export function parseShellEnvironment(output: string): Record<string, string> {
  const environment: Record<string, string> = {};
  for (const entry of output.split("\0")) {
    if (!entry) continue;
    const separator = entry.indexOf("=");
    if (separator < 1) throw new Error("sample Nix shell emitted a malformed environment entry");
    environment[entry.slice(0, separator)] = entry.slice(separator + 1);
  }
  return environment;
}

export function buildPrepareSudoCommand(
  preparePath: string,
  prepareArgs: string[],
  shellEnvironment: Record<string, string>,
  callerUid: number,
  callerGid: number,
): { command: string; args: string[] } {
  if (!path.isAbsolute(preparePath)) throw new Error("prepare executable must be an absolute path");
  if (!Number.isSafeInteger(callerUid) || callerUid < 0 || !Number.isSafeInteger(callerGid) || callerGid < 0) {
    throw new Error("caller uid/gid are invalid");
  }
  if (!shellEnvironment.PATH || !shellEnvironment.LD_LIBRARY_PATH || shellEnvironment.SGX_MODE !== "HW") {
    throw new Error("sample Nix shell lacks required PATH, LD_LIBRARY_PATH, or SGX_MODE=HW");
  }
  const assignments = ["SUDO_UID=" + callerUid, "SUDO_GID=" + callerGid];
  for (const key of canonicalRuntimeEnvKeys) {
    const value = shellEnvironment[key];
    if (value !== undefined) assignments.push(key + "=" + value);
  }
  assignments.push("SGX_MODE=" + shellEnvironment.SGX_MODE);
  // The canonical explorer builds its own ATFIELD_* runner environment and allowlists only runtime keys above.
  // In particular, omit inherited ATFIELD_BENCH_LEASE_ALL/HOST_RUNNER so acquisition bypasses the outer lease.
  return { command: "sudo", args: ["-n", "--", "env", "-i", ...assignments, preparePath, ...prepareArgs] };
}

function returnGeneratedFilesToCaller(directory: string, uid: number, gid: number, env: Record<string, string | undefined>): void {
  if (!existsSync(directory)) return;
  requireSuccess("restore generated file ownership", run("sudo", ["-n", "--", "chown", "-R", `${uid}:${gid}`, directory], root, env));
}

function captureSampleRuntimeEnv(shell: string, env: Record<string, string | undefined>): Record<string, string> {
  const cleanEnv = { ...env };
  for (const key of Object.keys(cleanEnv)) if (key.startsWith("ATFIELD_")) delete cleanEnv[key];
  const result = run(nix, ["develop", "--no-write-lock-file", root + "#" + shell, "--command", "env", "-0"], root, cleanEnv);
  requireSuccess("capture " + shell + " runtime environment", result);
  return parseShellEnvironment(result.stdout);
}

function prepareDynamic(sample: Sample, options: Options, env: Record<string, string | undefined>, acquisition: string, runDir: string): Size {
  const pdir = profileDir(sample), bundleFile = path.join(pdir, "profile-bundle.json");
  const workset = sampleWorksetPath(root, sample.group, sample.name, "protect");
  const acquireDir = sampleAcquireDir(root, sample.group, sample.name, "protect");
  console.log(sample.key + ": Profile");
  requireSuccess(sample.key + " Profile", run(bun, ["scripts/sample.ts", "profile", sample.group, sample.name, "protect"], root, env));
  if (!existsSync(bundleFile)) throw new Error("Profile bundle missing: " + bundleFile);

  mkdirSync(acquireDir, { recursive: true });
  rmSync(workset, { force: true });
  const prepare = path.join(acquisition, "bin", "atfield-acquire-prepare");
  const trace = path.join(acquisition, "lib", "libatfield_trace.so");
  const explore = path.join(acquisition, "lib", "libatfield_explore.so");
  for (const file of [prepare, trace, explore]) if (!existsSync(file)) throw new Error("acquisition output missing " + file);
  const shell = sample.group.replace("/", "-") + "-" + sample.name + "-protect";
  const corpus = path.join(sampleCorpusPath(root, sample.group, sample.name, "protect"), path.basename(runDir));
  mkdirSync(path.dirname(corpus), { recursive: true });
  const args = ["--bundle", bundleFile, "--collector", trace, "--explore-collector", explore, "--corpus", corpus, "--out", workset];
  if (options.budget !== undefined) args.push("--budget", String(options.budget));
  for (const value of options.mainArgs) args.push("--main-arg", value);
  if (options.supplemental) {
    for (const command of supplementalCommands(sample)) {
      args.push("--supplemental-command", JSON.stringify(command));
    }
  }
  console.log(sample.key + ": dynamic v2 acquisition");
  const shellEnvironment = captureSampleRuntimeEnv(shell, env);
  const callerUid = process.getuid?.(), callerGid = process.getgid?.();
  if (callerUid === undefined || callerGid === undefined) throw new Error("POSIX caller uid/gid are unavailable");
  const invocation = buildPrepareSudoCommand(prepare, args, shellEnvironment, callerUid, callerGid);
  const acquisitionResult = run(invocation.command, invocation.args, root, env);
  returnGeneratedFilesToCaller(corpus, callerUid, callerGid, env);
  requireSuccess(sample.key + " acquisition", acquisitionResult);
  if (!existsSync(workset) || jsonFile(workset).schema !== "atfield-workset-v2") throw new Error("acquisition did not produce a v2 workset: " + workset);
  const protectSize = buildMode(sample, "protect", env);
  prepareAndVerifyFinalV2(sample, options, env, acquisition, runDir, shellEnvironment, bundleFile, workset);
  return protectSize;
}

type ValidationIdentity = {
  manifestSha256: string;
  worksetSha256: string;
  capacityQ: number;
  signedFinalElfSha256: string;
  readyTableSha256: string;
  signedMeasurementFinalElfSha256: string;
  manifestFieldCount: number;
  productionConfigSha256: string;
  measurementConfigSha256: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function digestFile(filename: string): string {
  const hash = createHash("sha256");
  hash.update(readFileSync(filename));
  return hash.digest("hex");
}

function sortedStrings(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string" && item.length > 0)) {
    throw new Error(label + " must be an array of nonempty strings");
  }
  return [...new Set(value as string[])].sort();
}

export function validateFinalV2Batch(
  expectedFieldsInput: string[],
  summaries: Record<string, unknown>[],
  identity: ValidationIdentity,
): void {
  const expectedFields = sortedStrings(expectedFieldsInput, "target Fields");
  if (!expectedFields.length || expectedFields.length !== expectedFieldsInput.length) {
    throw new Error("frozen Final v2 target must contain a nonempty unique Field set");
  }
  if (!summaries.length) throw new Error("Final v2 validation batch is empty");
  const measured = new Set<string>();
  for (let index = 0; index < summaries.length; index++) {
    const summary = summaries[index]!;
    const label = "Final v2 validation execution " + (index + 1);
    if (summary.target_kind !== "final-v2" || summary.completion !== "complete" ||
        summary.measurement_complete !== true || summary.exit_code !== 0 || summary.timed_out !== false ||
        typeof summary.valid_ecall_count !== "number" || summary.valid_ecall_count < 1 ||
        summary.invalid_ecall_count !== 0) {
      throw new Error(label + " did not complete successfully on the frozen Final");
    }
    if (summary.selected_enclave_sha256 !== identity.signedMeasurementFinalElfSha256) {
      throw new Error(label + " selected a different signed measurement Final");
    }
    const validation = summary.final_v2_validation;
    if (!isRecord(validation) || validation.verdict !== "PASS" ||
        validation.observed_page_count !== 0 || validation.final_v2_verification_failure_count !== 0) {
      throw new Error(label + " failed its raw S3/AEX/measurement/readiness/SGX verification");
    }
    const observedIdentity = validation.final_v2_target;
    if (!isRecord(observedIdentity) ||
        observedIdentity.manifestSha256 !== identity.manifestSha256 ||
        observedIdentity.worksetSha256 !== identity.worksetSha256 ||
        observedIdentity.capacityQ !== identity.capacityQ ||
        observedIdentity.signedFinalElfSha256 !== identity.signedFinalElfSha256 ||
        observedIdentity.readyTableSha256 !== identity.readyTableSha256 ||
        observedIdentity.signedMeasurementFinalElfSha256 !== identity.signedMeasurementFinalElfSha256 ||
        observedIdentity.manifestFieldCount !== identity.manifestFieldCount ||
        observedIdentity.productionConfigSha256 !== identity.productionConfigSha256 ||
        observedIdentity.measurementConfigSha256 !== identity.measurementConfigSha256) {
      throw new Error(label + " used a different frozen Final/ReadyTable identity");
    }
    const fieldIds = sortedStrings(validation.measured_field_ids, label + " measured_field_ids");
    for (const fieldId of fieldIds) {
      if (!expectedFields.includes(fieldId)) throw new Error(label + " measured an unexpected Field " + fieldId);
      measured.add(fieldId);
    }
  }
  const missing = expectedFields.filter((fieldId) => !measured.has(fieldId));
  if (missing.length) throw new Error("Final v2 validation batch did not enter every target Field: " + missing.join(", "));
}

function validationCommands(sample: Sample, options: Options): Array<{ label: string; args: string[] }> {
  return [
    { label: "main", args: [...options.mainArgs] },
    ...(options.supplemental ? supplementalCommands(sample).map((args, index) => ({ label: "supplemental-" + (index + 1), args })) : []),
  ];
}

function prepareAndVerifyFinalV2(
  sample: Sample,
  options: Options,
  env: Record<string, string | undefined>,
  acquisition: string,
  runDir: string,
  shellEnvironment: Record<string, string>,
  bundleFile: string,
  worksetFile: string,
): void {
  const directory = buildDir(sample, "protect");
  const signer = path.join(shellEnvironment.SGX_SDK_ROOT ?? "", "bin", "x64", "sgx_sign");
  const key = path.join(root, "build", "test-signing-key.pem");
  for (const file of [signer, key, path.join(directory, "fields.json"), path.join(directory, "enclave.so"),
    path.join(directory, "enclave.signed.so"), path.join(directory, "pretouch-verified.json"),
    path.join(directory, "ready.json"), path.join(directory, "ready.bin")]) {
    if (!existsSync(file)) throw new Error("Final v2 build input is missing: " + file);
  }
  const workset = jsonFile(worksetFile);
  if (!Array.isArray(workset.fields) || workset.fields.length === 0 ||
      !workset.fields.every((field) => isRecord(field) && typeof field.id === "string")) {
    throw new Error("dynamic workset does not declare target Field IDs");
  }
  const expectedFields = sortedStrings(workset.fields.map((field) => (field as Record<string, unknown>).id), "workset Fields");
  if (expectedFields.length !== workset.fields.length) throw new Error("dynamic workset contains duplicate Field IDs");
  const fieldManifest = jsonFile(path.join(directory, "fields.json"));
  if (!Array.isArray(fieldManifest.fields) ||
      !fieldManifest.fields.every((field) => isRecord(field) && typeof field.id === "string")) {
    throw new Error("Final build does not declare its live Field IDs");
  }
  const manifestFields = sortedStrings(fieldManifest.fields.map((field) => (field as Record<string, unknown>).id), "Final Fields");
  if (manifestFields.length !== fieldManifest.fields.length ||
      manifestFields.length !== expectedFields.length ||
      manifestFields.some((fieldId, index) => fieldId !== expectedFields[index])) {
    throw new Error("frozen workset Field set differs from the Profile bundle Field set");
  }

  const measurementBuilder = path.join(acquisition, "bin", "atfield-acquire-prepare-final-v2-measurement");
  const freeze = path.join(acquisition, "bin", "atfield-acquire-freeze-final-v2");
  const runner = path.join(acquisition, "bin", "atfield-acquire-run");
  const collector = path.join(acquisition, "lib", "libatfield_trace.so");
  for (const file of [measurementBuilder, freeze, runner, collector]) {
    if (!existsSync(file)) throw new Error("Final v2 verification tool is missing: " + file);
  }

  console.log(sample.key + ": prepare frozen Final v2 measurement image");
  requireSuccess(sample.key + " Final v2 measurement preparation", run(measurementBuilder, [
    "--final-elf", path.join(directory, "enclave.so"),
    "--fields", path.join(directory, "fields.json"),
    "--capacity-q", String(workset.capacity_q),
    "--production-config-xml", path.join(root, sample.group, sample.name, "Enclave.config.xml"),
    "--sgx-sign", signer,
    "--key", key,
    "--out-dir", directory,
  ], root, env));

  const target = path.join(directory, "final-v2-run-target.json");
  rmSync(target, { force: true });
  console.log(sample.key + ": freeze Final/ReadyTable measurement identity");
  const freezeArgs = [
    "--bundle", bundleFile,
    "--workset", worksetFile,
    "--fields", path.join(directory, "fields.json"),
    "--final-elf", path.join(directory, "enclave.so"),
    "--signed-final-elf", path.join(directory, "enclave.signed.so"),
    "--pretouch-verified", path.join(directory, "pretouch-verified.json"),
    "--ready-table-json", path.join(directory, "ready.json"),
    "--ready-table", path.join(directory, "ready.bin"),
    "--measurement-patch-json", path.join(directory, "enclave.final.4gate.json"),
    "--measurement-final-elf", path.join(directory, "enclave.final.4gate.so"),
    "--signed-measurement-final-elf", path.join(directory, "enclave.final.4gate.signed.so"),
    "--production-config-xml", path.join(root, sample.group, sample.name, "Enclave.config.xml"),
    "--measurement-config-xml", path.join(directory, "Enclave.measurement.config.xml"),
    "--out", target,
  ];
  requireSuccess(sample.key + " Final v2 target freeze", run(freeze, freezeArgs, root, env));
  const manifest = jsonFile(target);
  const targetIdentity = manifest.identity;
  if (!isRecord(targetIdentity) || manifest.schema !== "atfield-final-v2-run-target-v2") {
    throw new Error("Final v2 freezer returned an invalid frozen target");
  }
  const expectedIdentity: ValidationIdentity = {
    manifestSha256: digestFile(target),
    worksetSha256: String(targetIdentity.workset_sha256),
    capacityQ: Number(targetIdentity.capacity_q),
    signedFinalElfSha256: String(targetIdentity.signed_final_elf_sha256),
    readyTableSha256: String(targetIdentity.ready_table_sha256),
    signedMeasurementFinalElfSha256: String(targetIdentity.signed_measurement_final_elf_sha256),
    manifestFieldCount: expectedFields.length,
    productionConfigSha256: String(targetIdentity.production_config_sha256),
    measurementConfigSha256: String(targetIdentity.measurement_config_sha256),
  };
  if (expectedIdentity.worksetSha256 !== digestFile(worksetFile) ||
      expectedIdentity.manifestFieldCount !== expectedFields.length ||
      expectedIdentity.capacityQ !== workset.capacity_q) {
    throw new Error("frozen Final v2 target does not bind the acquired workset and all its Fields");
  }

  const commands = validationCommands(sample, options);
  const summaries: Record<string, unknown>[] = [];
  for (const [index, validationCommand] of commands.entries()) {
    const artifactDir = path.join(runDir, "final-v2-verification", sample.group, sample.name, String(index + 1).padStart(2, "0"));
    mkdirSync(artifactDir, { recursive: true });
    console.log(sample.key + ": independent Final v2 replay " + validationCommand.label);
    const args = [
      "--bundle", bundleFile,
      "--final-v2-target", target,
      "--collector", collector,
      "--mode", "verify-pretouch",
      "--gate-mode", "c-preserve-tlb",
      "--timeout-ms", "600000",
      "--sample", sample.key + "/" + validationCommand.label,
      "--artifact-dir", artifactDir,
      "--",
      ...validationCommand.args,
    ];
    const callerUid = process.getuid?.(), callerGid = process.getgid?.();
    if (callerUid === undefined || callerGid === undefined) throw new Error("POSIX caller uid/gid are unavailable");
    const invocation = buildPrepareSudoCommand(runner, args, shellEnvironment, callerUid, callerGid);
    const result = run(invocation.command, invocation.args, root, env);
    returnGeneratedFilesToCaller(artifactDir, callerUid, callerGid, env);
    requireSuccess(sample.key + " Final v2 replay " + validationCommand.label, result);
    const summary = JSON.parse(result.stdout) as unknown;
    if (!isRecord(summary)) throw new Error(sample.key + " Final v2 replay did not emit a JSON summary");
    summaries.push(summary);
  }
  validateFinalV2Batch(expectedFields, summaries, expectedIdentity);
  console.log(sample.key + ": Final v2 independent replay PASS (" +
    summaries.length + " commands, " + expectedFields.length + " target Fields)");
}

function parseHelper(stdout: string): Record<string, unknown> {
  const line = stdout.trim().split(/\r?\n/).filter(Boolean).at(-1);
  if (!line) throw new Error("frequency helper emitted no JSON readback");
  const value: unknown = JSON.parse(line);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("frequency helper emitted invalid JSON");
  return value as Record<string, unknown>;
}

function checkFrequencyApply(value: Record<string, unknown>): void {
  if (value.action !== "apply" || !Array.isArray(value.isolated_cpus) || !Array.isArray(value.policies) || !value.policies.length) {
    throw new Error("frequency helper apply output lacks policy readback");
  }
  const cpus = new Set(value.isolated_cpus.filter((cpu): cpu is number => Number.isInteger(cpu)));
  const bases = new Set<string>();
  for (const item of value.policies) {
    if (!item || typeof item !== "object") throw new Error("invalid frequency policy readback");
    const policy = item as Record<string, unknown>;
    if (typeof policy.base_frequency !== "string" || policy.base_frequency !== policy.scaling_min_freq || policy.base_frequency !== policy.scaling_max_freq || !Array.isArray(policy.cpus) || !policy.cpus.every((cpu) => cpus.has(cpu as number))) {
      throw new Error("frequency helper readback does not show isolated fixed-base policies");
    }
    bases.add(policy.base_frequency);
  }
  const turbo = value.no_turbo as Record<string, unknown> | null;
  if (bases.size !== 1 || !turbo || turbo.value !== "1") throw new Error("frequency helper did not confirm a common non-turbo base");
}

function metric(run: Run, sample: Sample): number | undefined {
  return sample.kind === "micro" ? run.hostEcallNs : run.hostWallNs;
}

function printReport(samples: Sample[], runs: Run[], sizes: Map<string, Partial<Sizes>>, failures: string[], trials: number): void {
  console.log("\nSample\tMetric\tRaw median (n/trials)\tDynamic median\tFull REG median\tProtect/raw paired\tNaive/raw paired\tProtect/naive paired\tFailures raw/protect/naive");
  for (const sample of samples) {
    const selected = (mode: Mode) => runs.filter((run) => run.sample.key === sample.key && run.mode === mode);
    const values = new Map(modes.map((mode) => [mode, median(selected(mode).filter((run) => run.status === "success").map((run) => metric(run, sample)!).filter(Number.isFinite))]));
    const cell = (mode: Mode) => {
      const successCount = selected(mode).filter((run) => run.status === "success" && metric(run, sample) !== undefined).length;
      const value = values.get(mode);
      return (value === null ? "FAIL" : Math.round(value).toString()) + " (" + successCount + "/" + trials + ")";
    };
    const paired = (numerator: Mode, denominator: Mode) => {
      const byTrial = new Map<number, number>();
      for (const run of selected(denominator)) {
        const value = metric(run, sample);
        if (run.status === "success" && value !== undefined && Number.isFinite(value) && value > 0) byTrial.set(run.trial, value);
      }
      const ratios: number[] = [];
      for (const run of selected(numerator)) {
        const value = metric(run, sample), baseline = byTrial.get(run.trial);
        if (run.status === "success" && value !== undefined && Number.isFinite(value) && value > 0 && baseline !== undefined) {
          ratios.push(value / baseline);
        }
      }
      const value = median(ratios);
      return value === null || !Number.isFinite(value) ? "invalid (0 pairs)" : value.toFixed(4) + " (" + ratios.length + "/" + trials + " pairs)";
    };
    const counts = modes.map((mode) => selected(mode).filter((run) => run.status === "failed").length).join("/");
    console.log([sample.key, sample.kind === "micro" ? "host_ecall_ns" : "host_wall_ns", cell("raw"), cell("protect"), cell("protect-naive"), paired("protect", "raw"), paired("protect-naive", "raw"), paired("protect", "protect-naive"), counts].join("\t"));
  }
  console.log("\nBinary sizes\tSample\tMode\tSigned enclave bytes\tPT_LOAD file bytes\tPT_LOAD memory bytes\tExecutable pages");
  for (const sample of samples) for (const mode of modes) {
    const size = sizes.get(sample.key)?.[mode];
    if (size) console.log(["", sample.key, mode, size.enclaveBytes, size.ptLoadFileBytes ?? "unavailable", size.ptLoadMemoryBytes ?? "unavailable", size.executablePages ?? "unavailable"].join("\t"));
  }
  if (samples.some((sample) => sample.kind === "micro")) {
    console.log("\nMicro enclave TSC ticks\tSample\tMode\tMedian ticks per run");
    for (const sample of samples.filter((item) => item.kind === "micro")) for (const mode of modes) {
      const value = median(runs.filter((run) => run.sample.key === sample.key && run.mode === mode && run.status === "success" && run.enclaveTicks !== undefined).map((run) => run.enclaveTicks!));
      console.log(["", sample.key, mode, value ?? "FAIL"].join("\t"));
    }
  }
  if (failures.length) {
    console.error("\nFailures (" + failures.length + "):");
    for (const failure of failures) console.error("- " + failure);
  }
  console.log("Final v2 validation independently replays each declared main/supplemental command before timing; this is not held-out input coverage.");
  console.log("Timed run-built trials do not load the verification collector; failed runs remain in this report and optional CSV.");
}

function csv(value: unknown): string {
  const text = value === undefined || value === null ? "" : String(value);
  return /[",\r\n]/.test(text) ? "\"" + text.replace(/"/g, "\"\"") + "\"" : text;
}

function writeCsv(filename: string, runs: Run[], sizes: Map<string, Partial<Sizes>>): void {
  const lines = ["sample,trial,mode,status,host_wall_ns,host_ecall_ns,enclave_tsc_ticks,iterations,failure,enclave_bytes,pt_load_file_bytes,pt_load_memory_bytes,executable_pages"];
  for (const run of runs) {
    const size = sizes.get(run.sample.key)?.[run.mode];
    lines.push([run.sample.key, run.trial, run.mode, run.status, run.hostWallNs, run.hostEcallNs, run.enclaveTicks, run.iterations,
      run.error, size?.enclaveBytes, size?.ptLoadFileBytes, size?.ptLoadMemoryBytes, size?.executablePages].map(csv).join(","));
  }
  const target = path.resolve(root, filename);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, lines.join("\n") + "\n", "utf8");
}

async function main(): Promise<number> {
  let options: Options | { help: true };
  try { options = parseArgs(process.argv.slice(2)); }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); console.error(usage()); return 2; }
  if ("help" in options) { console.log(usage()); return 0; }
  let samples: Sample[];
  try {
    const discovered = discoverSamples();
    const selected = new Set(options.samples);
    samples = selected.size ? discovered.filter((sample) => selected.has(sample.key)) : discovered;
    if (samples.length !== selected.size && selected.size) {
      throw new Error("unknown --sample: " + [...selected].filter((key) => !samples.some((sample) => sample.key === key)).join(", "));
    }
  }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); return 2; }
  const tasks = schedule(samples, options.trials, options.seed);
  if (options.dryRun) {
    console.log(JSON.stringify({ samples: samples.map((sample) => sample.key), modes, trials: options.trials, seed: options.seed,
      default_main_args: options.mainArgs,
      supplemental_commands: Object.fromEntries(samples.map((sample) =>
        [sample.key, options.supplemental ? supplementalCommands(sample) : []])),
      first_scheduled_runs: tasks.slice(0, 12).map((task) => [task.trial, task.sample.key, task.mode]) }, null, 2));
    return 0;
  }

  const runId = new Date().toISOString().replace(/[:.]/g, "-") + "-" + process.pid + "-" + options.seed;
  const runDir = path.join(root, "build", "bench", "measure", runId);
  mkdirSync(runDir, { recursive: true });
  console.log("Benchmark " + runId + ": " + samples.length + " samples, " + options.trials + " paired trials, seed " + options.seed);
  console.log("Main arguments " + JSON.stringify(options.mainArgs) + "; supplemental checks " +
    (options.supplemental ? "enabled" : "disabled") + "; acquisition budget " + (options.budget ?? "helper default"));
  console.log("Run artifacts: " + runDir);
  const env: Record<string, string | undefined> = { ...process.env, ATFIELD_BENCH_LEASE_ALL: "1", ATFIELD_HOST_RUNNER: "on", ATFIELD_READINESS_BACKEND: "kernel" };
  delete env.ATFIELD_FROZEN_WORKSET;
  const sizes = new Map<string, Partial<Sizes>>(), modeFailures = new Map<string, Partial<Record<Mode, string>>>(), failures: string[] = [], runs: Run[] = [];
  const finalV2GateFailures = new Map<string, string>();
  let bundle = "", acquisition = "", frequency = "", state = path.join(runDir, "frequency-state.json"), applied = false, restored = false;
  let bundleFailure = "", acquisitionFailure = "";
  try {
    console.log("Resolving pinned implement bundle");
    bundle = storeOutput(".#atfield-bundle", env);
    env.ATFIELD_IMPLEMENT_ROOT = bundle;
  } catch (error) {
    bundleFailure = error instanceof Error ? error.message : String(error);
    failures.push("implement bundle setup: " + bundleFailure);
    console.error(bundleFailure);
  }
  if (bundle) {
    try {
      console.log("Resolving acquisition tools");
      acquisition = storeOutput(".#atfield-acquisition", env);
    } catch (error) {
      acquisitionFailure = error instanceof Error ? error.message : String(error);
      failures.push("acquisition package setup: " + acquisitionFailure);
      console.error(acquisitionFailure);
    }
  }
  const recordFailure = (sample: Sample, mode: Mode, error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    const byMode = modeFailures.get(sample.key) ?? {};
    byMode[mode] = message;
    modeFailures.set(sample.key, byMode);
    failures.push(sample.key + " " + mode + " preparation: " + message);
    console.error(sample.key + " " + mode + " preparation failed: " + message);
  };
  for (const sample of samples) {
    const sampleSizes: Partial<Sizes> = {};
    console.log("Preparing baselines " + sample.key);
    for (const mode of ["raw", "protect-naive"] as const) {
      try {
        if (bundleFailure) throw new Error("implement bundle unavailable: " + bundleFailure);
        sampleSizes[mode] = buildMode(sample, mode, env);
      } catch (error) { recordFailure(sample, mode, error); }
    }
    sizes.set(sample.key, sampleSizes);
  }
  for (const sample of samples) {
    const sampleSizes = sizes.get(sample.key)!;
    try {
      if (bundleFailure) throw new Error("implement bundle unavailable: " + bundleFailure);
      if (acquisitionFailure) throw new Error("acquisition package unavailable: " + acquisitionFailure);
      sampleSizes.protect = prepareDynamic(sample, options, env, acquisition, runDir);
    } catch (error) {
      recordFailure(sample, "protect", error);
      finalV2GateFailures.set(sample.key, error instanceof Error ? error.message : String(error));
    }
  }

  const ready = samples.some((sample) => modes.some((mode) => sizes.get(sample.key)?.[mode] !== undefined));
  if (ready) {
    try {
      frequency = path.join(bundle || (bundle = storeOutput(".#atfield-bundle", env)), "bin", "atfield-bench-frequency");
      if (!existsSync(frequency)) throw new Error("frequency helper missing: " + frequency);
      rmSync(state, { force: true });
      const sudo = command("sudo");
      console.log("Applying fixed non-turbo frequency policy");
      const result = run(sudo, ["-n", "--", frequency, "apply", "--state", state]);
      if (result.code !== 0) throw new Error("frequency apply failed (exit " + result.code + "): " + detail(result));
      const readback = parseHelper(result.stdout);
      checkFrequencyApply(readback);
      applied = true;
      console.log("Frequency apply/readback: " + JSON.stringify(readback));

      for (const task of tasks) {
        const gateFailure = finalV2GateFailures.get(task.sample.key);
        if (task.mode === "protect" && gateFailure) {
          runs.push({ ...task, status: "failed", error: "Final v2 verification failed; protect timing is blocked: " + gateFailure });
          continue;
        }
        const prepError = modeFailures.get(task.sample.key)?.[task.mode];
        if (prepError) {
          runs.push({ ...task, status: "failed", error: "preparation failed: " + prepError });
          continue;
        }
        const resultRow: Run = { ...task, status: "failed" };
        const runFile = path.join(buildDir(task.sample, task.mode), "run.json");
        rmSync(runFile, { force: true });
        console.log("trial " + task.trial + "/" + options.trials + " " + task.sample.key + " " + task.mode);
        let executed: Result | undefined;
        try {
          executed = run(bun, ["scripts/sample.ts", "run-built", task.sample.group, task.sample.name, task.mode, ...options.mainArgs], root, env);
          if (!executed) throw new Error("run-built was not launched");
          if (executed.code !== 0) throw new Error("run-built exit " + executed.code + ": " + detail(executed));
          const metadata = jsonFile(runFile);
          if (metadata.exitCode !== 0) throw new Error("run.json reports nonzero exitCode");
          const wall = Number(metadata.host_wall_ns);
          if (!Number.isFinite(wall) || wall <= 0) throw new Error("run.json host_wall_ns is invalid");
          resultRow.hostWallNs = wall;
          if (task.sample.kind === "micro") {
            const measured = parseMicro(executed.stdout, task.sample.name);
            resultRow.hostEcallNs = measured.ns; resultRow.enclaveTicks = measured.ticks; resultRow.iterations = measured.count;
          }
          resultRow.status = "success";
        } catch (error) {
          resultRow.error = error instanceof Error ? error.message : String(error);
          failures.push(task.sample.key + " trial " + task.trial + " " + task.mode + ": " + resultRow.error);
          console.error(resultRow.error);
          if (executed?.stdout) console.error(executed.stdout.slice(-5000));
          if (executed?.stderr) console.error(executed.stderr.slice(-5000));
        }
        runs.push(resultRow);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failures.push(message);
      console.error(message);
      while (runs.length < tasks.length) {
        const task = tasks[runs.length]!;
        runs.push({ ...task, status: "failed", error: "measurement setup failed: " + message });
      }
    } finally {
      if (existsSync(state) && frequency) {
        try {
          const result = run(command("sudo"), ["-n", "--", frequency, "restore", "--state", state]);
          if (result.code !== 0) throw new Error("frequency restore failed (exit " + result.code + "): " + detail(result));
          const readback = parseHelper(result.stdout);
          if (readback.action !== "restore") throw new Error("frequency helper did not confirm restore");
          restored = true;
          console.log("Frequency restore/readback: " + JSON.stringify(readback));
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          const recovery = existsSync(state) ? "recovery state retained at " + state : "recovery state file absent; verify the restored policy readback";
          failures.push(message + "; " + recovery);
          console.error(message + "; " + recovery);
        }
      } else if (applied) {
        failures.push("frequency apply returned success without its recovery state; cannot confirm restore");
      }
    }
  } else {
    for (const task of tasks) runs.push({ ...task, status: "failed", error: "preparation failed: " + (modeFailures.get(task.sample.key)?.[task.mode] ?? "not attempted") });
  }

  printReport(samples, runs, sizes, failures, options.trials);
  if (options.csv) writeCsv(options.csv, runs, sizes);
  if (applied && !restored) return 1;
  return failures.length ? 1 : 0;
}

if (import.meta.main) process.exitCode = await main();
