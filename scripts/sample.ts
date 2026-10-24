#!/usr/bin/env bun
import { createHash, randomUUID } from "node:crypto";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sampleBuildDir, sampleWorksetPath } from "./sample-paths.ts";

type Group = "anchor" | "bench/micro" | "bench/application";
type Mode = "raw" | "anchor" | "protect" | "protect-naive";
type Action = "build" | "profile" | "run" | "run-built";
interface Sample { action: Action; group: Group; name: string; mode: Mode; hostArgs: string[]; }

const scriptPath = fileURLToPath(import.meta.url);
const projectRoot = resolve(dirname(scriptPath), "..");
const usage = "usage: bun scripts/sample.ts build GROUP NAME MODE | bun scripts/sample.ts profile GROUP NAME protect | bun scripts/sample.ts run|run-built GROUP NAME MODE [host args...]";

function isProtectMode(mode: Mode): boolean {
  return mode === "protect" || mode === "protect-naive";
}

function cmakeMode(mode: Mode): "raw" | "anchor" | "protect" {
  return isProtectMode(mode) ? "protect" : mode;
}

function fail(message: string, code = 64): never {
  console.error(message);
  process.exit(code);
}

function parseArgs(args: string[]): Sample {
  const action = args[0];
  if (action !== "build" && action !== "profile" && action !== "run" && action !== "run-built") fail(usage);
  if (args.length < 4 || ((action === "build" || action === "profile") && args.length !== 4)) fail(usage);
  const [, groupArg, name, modeArg, ...hostArgs] = args;
  if (groupArg !== "anchor" && groupArg !== "bench/micro" && groupArg !== "bench/application") {
    fail("GROUP must be anchor, bench/micro, or bench/application");
  }
  if (modeArg !== "raw" && modeArg !== "anchor" && modeArg !== "protect" && modeArg !== "protect-naive") fail("MODE must be raw, anchor, protect, or protect-naive");
  if (groupArg === "anchor" && isProtectMode(modeArg as Mode)) fail("anchor demonstrations have no Field or protect mode");
  if (action === "profile" && modeArg !== "protect") fail("profile action requires dynamic protect mode");
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) fail("NAME must use lower-case words separated by hyphens");
  const group = groupArg as Group;
  const mode = modeArg as Mode;
  const sourceRoot = join(projectRoot, group, name);
  if (!existsSync(join(sourceRoot, "CMakeLists.txt"))) fail(`unknown ${group} sample: ${name}`);
  if ((action === "run" || action === "run-built") && group === "anchor" && hostArgs.length > 0) fail("anchor samples do not accept host arguments");
  if ((action === "run" || action === "run-built") && isProtectMode(mode)) validateProtectRunnerOptions();
  return { action, group, name, mode, hostArgs };
}

function validateProtectRunnerOptions(): void {
  const runnerMode = process.env.ATFIELD_HOST_RUNNER ?? "on";
  const readinessBackend = process.env.ATFIELD_READINESS_BACKEND ?? "kernel";
  if (runnerMode !== "on" && runnerMode !== "off") fail("ATFIELD_HOST_RUNNER must be 'on' or 'off'");
  if (readinessBackend !== "kernel" && readinessBackend !== "userspace") fail("ATFIELD_READINESS_BACKEND must be 'kernel' or 'userspace'");
  if (runnerMode === "off" && process.env.ATFIELD_READINESS_BACKEND !== "userspace") {
    fail("ATFIELD_HOST_RUNNER=off is research-only and requires explicit ATFIELD_READINESS_BACKEND=userspace");
  }
}

function run(cmd: string[], options: { cwd?: string; env?: Record<string, string | undefined> } = {}): number {
  const result = Bun.spawnSync({ cmd, cwd: options.cwd, env: options.env, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  return result.exitCode ?? 1;
}

function ensureExecutable(path: string, message: string, code = 66): void {
  try { accessSync(path, constants.X_OK); }
  catch { fail(message, code); }
}

function commandExists(command: string): boolean {
  if (command.includes("/")) {
    try { accessSync(command, constants.X_OK); return true; } catch { return false; }
  }
  return (process.env.PATH ?? "").split(":").some((directory) => {
    try { accessSync(join(directory, command), constants.X_OK); return true; } catch { return false; }
  });
}

function ensureNixShell(sample: Sample): void {
  const marker = `${sample.group}/${sample.name}/${sample.mode}`;
  if (process.env.ATFIELD_SAMPLE_SHELL === marker) {
    if (isProtectMode(sample.mode)) {
      const implementRoot = process.env.ATFIELD_IMPLEMENT_ROOT;
      if (!implementRoot || !existsSync(implementRoot)) {
        fail("ATFIELD_IMPLEMENT_ROOT is missing or invalid in protect shell", 66);
      }
      try {
        if (!statSync(implementRoot).isDirectory()) fail("ATFIELD_IMPLEMENT_ROOT is missing or invalid in protect shell", 66);
      } catch { fail("ATFIELD_IMPLEMENT_ROOT is missing or invalid in protect shell", 66); }
      process.env.ATFIELD_IMPLEMENT_ROOT = realpathSync(implementRoot);
    }
    return;
  }

  const shellName = `${sample.group.replace("/", "-")}-${sample.name}-${sample.mode}`;
  const envArgs = [`ATFIELD_SAMPLE_SHELL=${marker}`];
  if (isProtectMode(sample.mode) && process.env.ATFIELD_IMPLEMENT_ROOT) {
    envArgs.push(`ATFIELD_IMPLEMENT_ROOT=${process.env.ATFIELD_IMPLEMENT_ROOT}`);
  }
  for (const name of ["ATFIELD_FROZEN_WORKSET", "ATFIELD_BENCH_LEASE_ALL", "ATFIELD_HOST_RUNNER", "ATFIELD_READINESS_BACKEND"]) {
    const value = process.env[name];
    if (value !== undefined) envArgs.push(`${name}=${value}`);
  }
  const result = run([
    "nix", "develop", "--no-write-lock-file", `${projectRoot}#${shellName}`,
    "--command", "env", ...envArgs, "bun", scriptPath, sample.action, sample.group, sample.name, sample.mode, ...sample.hostArgs,
  ]);
  process.exit(result);
}

function requireVariables(names: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const name of names) {
    const value = process.env[name];
    if (!value) fail(`${name} is missing from the sample Nix shell`, 66);
    out[name] = value;
  }
  return out;
}

function samplePaths(sample: Sample) {
  return { buildDir: sampleBuildDir(projectRoot, sample.group, sample.name, sample.mode) };
}

function frozenWorkset(sample: Sample): string {
  const configured = process.env.ATFIELD_FROZEN_WORKSET;
  return configured ? resolve(configured) : sampleWorksetPath(projectRoot, sample.group, sample.name, sample.mode);
}

export function isProfileFinalCacheTransition(
  cachedProfileOnly: string | undefined,
  cachedWorkset: string | undefined,
  wantedProfileOnly: "ON" | "OFF",
  wantedWorkset: string,
  expectedFinalWorkset: string,
): boolean {
  return (
    cachedProfileOnly === "ON" && cachedWorkset === "" &&
      wantedProfileOnly === "OFF" && wantedWorkset === expectedFinalWorkset
  ) || (
    cachedProfileOnly === "OFF" && cachedWorkset === expectedFinalWorkset &&
      wantedProfileOnly === "ON" && wantedWorkset === ""
  );
}

function requireFrozenWorkset(sample: Sample): string {
  if (sample.mode === "protect-naive") return "";
  const path = frozenWorkset(sample);
  if (!existsSync(path)) fail(`dynamic protect requires an existing frozen v2 workset: ${path}`, 66);
  let workset: Record<string, unknown>;
  try { workset = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>; }
  catch { fail(`dynamic protect workset is not valid JSON: ${path}`, 66); }
  if (workset!.schema !== "atfield-workset-v2") fail(`dynamic protect requires atfield-workset-v2: ${path}`, 66);
  return path;
}

function buildSample(sample: Sample): void {
  const { buildDir } = samplePaths(sample);
  const dynamicProfile = sample.action === "profile";
  const worksetPath = sample.mode === "protect" && !dynamicProfile ? requireFrozenWorkset(sample) : "";
  ensureNixShell(sample);
  const tool = requireVariables([
    "ATFIELD_CC", "ATFIELD_CXX", "ATFIELD_LLD", "ATFIELD_AR", "ATFIELD_RANLIB", "ATFIELD_NM",
    "ATFIELD_IMPLEMENT_ROOT", "ATFIELD_CMAKE_MODULE",
    "ATFIELD_OBJCOPY", "ATFIELD_READELF", "ATFIELD_LLC", "SGX_SDK_ROOT", "SGX_PSW_ROOT",
    "SGX_TRUSTED_LIB_ROOT",
  ]);
  tool.SGX_ENCLAVE_CLANG = process.env.SGX_ENCLAVE_CLANG ?? "";
  const cmakeArgs: string[] = [];
  for (const name of [
    "CURVE25519_DONNA_SGX_ROOT", "YESCRYPT_SGX_ROOT", "WOLFSSL_SGX_ROOT", "QE3_SOURCE_ROOT", "EHSM_SOURCE_ROOT",
    "SGXWALLET_SOURCE_ROOT", "SIGNAL_CDS_SOURCE_ROOT", "SGXSSL_ROOT", "SGX_GMP_ROOT", "SGX_MCL_ROOT",
  ]) {
    const value = process.env[name];
    if (value) cmakeArgs.push(`-D${name}=${value}`);
  }

  if (isProtectMode(sample.mode)) {
    const implementRoot = process.env.ATFIELD_IMPLEMENT_ROOT;
    if (!implementRoot || !existsSync(implementRoot)) fail("ATFIELD_IMPLEMENT_ROOT is missing or invalid in protect shell", 66);
    const root = realpathSync(implementRoot);
    process.env.ATFIELD_IMPLEMENT_ROOT = root;
    process.env.ATFIELD_FIELD_BOUNDARY = "1";
    const fieldTool = join(root, "bin", "atfield-field");
    ensureExecutable(fieldTool, `implement Field tool is missing: ${fieldTool}`);
    const enclaveClang = join(root, "bin", "atfield-enclave-clang");
    ensureExecutable(enclaveClang, `implement enclave compiler is missing: ${enclaveClang}`);
    tool.SGX_ENCLAVE_CLANG = enclaveClang;
    process.env.ATFIELD_FIELD_TOOL = fieldTool;
    cmakeArgs.push(`-DATFIELD_FIELD_TOOL=${fieldTool}`);
    const libraryIrManifests = process.env.ATFIELD_LIBRARY_IR_MANIFESTS;
    if (!libraryIrManifests) fail("ATFIELD_LIBRARY_IR_MANIFESTS is missing from protect shell", 66);
    cmakeArgs.push(`-DATFIELD_LIBRARY_IR_MANIFESTS=${libraryIrManifests}`);
  }

  const cachePath = join(buildDir, "CMakeCache.txt");
  if (existsSync(cachePath)) {
    const cacheLines = readFileSync(cachePath, "utf8").split("\n");
    const cacheValue = (name: string): string | undefined => {
      const line = cacheLines.find((item) => item.startsWith(name + ":"));
      return line?.slice(line.indexOf("=") + 1);
    };
    const cachedWorkset = cacheValue("ATFIELD_FROZEN_WORKSET");
    const wantedProfileOnly = dynamicProfile ? "ON" : "OFF";
    const cacheTransition = sample.mode === "protect" && isProfileFinalCacheTransition(
      cacheValue("ATFIELD_PROFILE_ONLY"), cachedWorkset, wantedProfileOnly, worksetPath,
      frozenWorkset(sample),
    );
    const wantRoots = cmakeArgs.map((arg) => {
      const assignment = arg.slice(2);
      const equals = assignment.indexOf("=");
      return [assignment.slice(0, equals), assignment.slice(equals + 1)] as const;
    });
    if (
      cacheValue("CMAKE_C_COMPILER") !== tool.ATFIELD_CC ||
      cacheValue("ATFIELD_IMPLEMENT_ROOT") !== tool.ATFIELD_IMPLEMENT_ROOT ||
      cacheValue("SGX_SDK_ROOT") !== tool.SGX_SDK_ROOT ||
      ((cachedWorkset !== worksetPath || cacheValue("ATFIELD_PROFILE_ONLY") !== wantedProfileOnly) && !cacheTransition) ||
      wantRoots.some(([name, value]) => cacheValue(name) !== value)
    ) {
      const preservedBuildDir = `${buildDir}.cache-mismatch-${Date.now()}-${randomUUID()}`;
      renameSync(buildDir, preservedBuildDir);
      console.error(`CMake cache mismatch; preserved prior build directory at ${preservedBuildDir}`);
    }
  }

  const configureArgs = [
    "-S", projectRoot, "-B", buildDir, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=",
    `-DCMAKE_C_COMPILER=${tool.ATFIELD_CC}`, `-DCMAKE_CXX_COMPILER=${tool.ATFIELD_CXX}`,
    `-DCMAKE_LINKER=${tool.ATFIELD_LLD}`, `-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=${tool.ATFIELD_LLD}`,
    `-DCMAKE_AR=${tool.ATFIELD_AR}`, `-DCMAKE_RANLIB=${tool.ATFIELD_RANLIB}`,
    `-DCMAKE_C_COMPILER_AR=${tool.ATFIELD_AR}`, `-DCMAKE_C_COMPILER_RANLIB=${tool.ATFIELD_RANLIB}`,
    `-DCMAKE_CXX_COMPILER_AR=${tool.ATFIELD_AR}`, `-DCMAKE_CXX_COMPILER_RANLIB=${tool.ATFIELD_RANLIB}`,
    `-DCMAKE_NM=${tool.ATFIELD_NM}`, `-DCMAKE_OBJCOPY=${tool.ATFIELD_OBJCOPY}`,
    `-DCMAKE_READELF=${tool.ATFIELD_READELF}`, "-DCMAKE_EXPORT_COMPILE_COMMANDS=OFF",
    `-DATFIELD_GROUP=${sample.group}`, `-DATFIELD_SAMPLE=${sample.name}`, `-DATFIELD_MODE=${cmakeMode(sample.mode)}`,
    `-DATFIELD_IMPLEMENT_ROOT=${tool.ATFIELD_IMPLEMENT_ROOT}`,
    `-DATFIELD_CMAKE_MODULE=${tool.ATFIELD_CMAKE_MODULE}`,
    `-DATFIELD_LLC=${tool.ATFIELD_LLC}`,
    `-DATFIELD_TEST_SIGNING_KEY=${join(projectRoot, "build", "test-signing-key.pem")}`,
    `-DSGX_ENCLAVE_CLANG=${tool.SGX_ENCLAVE_CLANG}`, `-DSGX_SDK_ROOT=${tool.SGX_SDK_ROOT}`,
    `-DSGX_PSW_ROOT=${tool.SGX_PSW_ROOT}`, `-DSGX_TRUSTED_LIB_ROOT=${tool.SGX_TRUSTED_LIB_ROOT}`,
    `-DATFIELD_FROZEN_WORKSET=${worksetPath}`,
    `-DATFIELD_WORKSET_POLICY=${sample.mode === "protect-naive" ? "naive" : "dynamic"}`,
    `-DATFIELD_PROFILE_ONLY=${dynamicProfile ? "ON" : "OFF"}`,
    ...cmakeArgs,
  ];
  const compdbPath = join(buildDir, "compile_commands.json");
  const prevCompdb = existsSync(compdbPath) ? readFileSync(compdbPath, "utf8") : null;
  const prevStat = existsSync(compdbPath) ? statSync(compdbPath) : null;
  const configureStatus = run(["cmake", ...configureArgs]);
  if (configureStatus !== 0) process.exit(configureStatus);
  const compdb = Bun.spawnSync({ cmd: ["ninja", "-C", buildDir, "-t", "compdb"], stdout: "pipe", stderr: "inherit" });
  if (compdb.exitCode !== 0) process.exit(compdb.exitCode);
  const compdbEntries = (JSON.parse(new TextDecoder().decode(compdb.stdout)) as Array<Record<string, unknown>>)
    .filter((entry) => typeof entry.command === "string" && entry.command.trim().length > 0 && String(entry.command).includes(" -c ") && String(entry.command).includes("--cmake-launcher"));
  const nextCompdb = JSON.stringify(compdbEntries, null, 2) + "\n";
  writeFileSync(compdbPath, nextCompdb);
  if (prevCompdb === nextCompdb && prevStat !== null) {
    utimesSync(compdbPath, prevStat.atime, prevStat.mtime);
  }
  const buildStatus = run(["cmake", "--build", buildDir, "--parallel"]);
  if (buildStatus !== 0) process.exit(buildStatus);
}

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function validateRunnerLibraryPath(libraryPath = process.env.LD_LIBRARY_PATH ?? ""): string {
  if (!libraryPath) throw new Error("Nix shell LD_LIBRARY_PATH is empty; refusing root protect launch");
  for (const directory of libraryPath.split(":")) {
    let isDirectory = false;
    if (directory && directory.startsWith("/nix/store/")) {
      try { isDirectory = statSync(directory).isDirectory(); } catch { /* invalid or missing path */ }
    }
    if (!isDirectory) {
      throw new Error(`protect runner only accepts existing Nix store library directories in LD_LIBRARY_PATH: ${directory}`);
    }
  }
  return libraryPath;
}

function runSample(sample: Sample): void {
  const { buildDir } = samplePaths(sample);
  const runJson = join(buildDir, "run.json");
  rmSync(runJson, { force: true });
  ensureNixShell(sample);

  const runnerMode = process.env.ATFIELD_HOST_RUNNER ?? "on";
  const readinessBackend = process.env.ATFIELD_READINESS_BACKEND ?? "kernel";
  let runnerPath = "";
  let runnerLibraryPath = "";
  const benchLeaseAll = sample.action === "run-built" && process.env.ATFIELD_BENCH_LEASE_ALL === "1";
  if (isProtectMode(sample.mode) || benchLeaseAll) {
    process.env.ATFIELD_READINESS_BACKEND = readinessBackend;
    if (runnerMode === "on" || benchLeaseAll) {
      const implementRoot = process.env.ATFIELD_IMPLEMENT_ROOT;
      if (!implementRoot || !existsSync(implementRoot)) fail("ATFIELD_IMPLEMENT_ROOT is missing or invalid in protect shell", 66);
      try { runnerLibraryPath = validateRunnerLibraryPath(); }
      catch (error) { fail(error instanceof Error ? error.message : String(error), 69); }
      runnerPath = join(realpathSync(implementRoot), "bin", "atfield-host");
      ensureExecutable(runnerPath, `protect host runner is missing or not executable: ${runnerPath}`);
      if (!commandExists("sudo")) fail("sudo is required to launch protect hosts through atfield-host", 69);
    } else {
      console.error("RESEARCH ONLY: host CPU lease is bypassed; userspace-readiness is selected explicitly");
    }
  }

  if (sample.action === "run") buildSample(sample);
  runBuiltSample(sample, buildDir, runJson, runnerMode, readinessBackend, runnerPath, runnerLibraryPath);
}

function runBuiltSample(sample: Sample, buildDir: string, runJson: string, runnerMode: string,
  readinessBackend: string, runnerPath: string, runnerLibraryPath: string): void {
  if (isProtectMode(sample.mode)) validateBuiltProtectIdentity(sample, buildDir);
  if (process.env.SGX_MODE !== "HW") fail("SGX_MODE must be HW; simulation fallback is disabled", 69);
  let device = "/dev/sgx_enclave";
  if (existsSync("/dev/sgx/enclave")) device = "/dev/sgx/enclave";
  try { accessSync(device, constants.R_OK | constants.W_OK); }
  catch { fail(`SGX hardware device is unavailable or not accessible: ${device}`, 69); }
  const hostPath = join(buildDir, "host");
  const imagePath = join(buildDir, "enclave.signed.so");
  ensureExecutable(hostPath, `build output is incomplete: ${buildDir}`);
  if (!existsSync(imagePath)) fail(`build output is incomplete: ${buildDir}`, 66);

  const imageShaBefore = sha256(imagePath);
  const hostShaBefore = sha256(hostPath);
  let command: string[];
  if ((isProtectMode(sample.mode) && runnerMode === "on") || (sample.action === "run-built" && process.env.ATFIELD_BENCH_LEASE_ALL === "1")) {
    const runnerEnv = [`LD_LIBRARY_PATH=${runnerLibraryPath}`];
    if (isProtectMode(sample.mode)) runnerEnv.push(`ATFIELD_READINESS_BACKEND=${readinessBackend}`);
    command = ["sudo", "--", runnerPath, "run", "--", "/usr/bin/env", ...runnerEnv, "./host", ...sample.hostArgs];
  } else {
    command = ["./host", ...sample.hostArgs];
  }
  const env = isProtectMode(sample.mode) && runnerMode === "off"
    ? { ...process.env, ATFIELD_READINESS_BACKEND: readinessBackend }
    : process.env;
  const hostStart = process.hrtime.bigint();
  const exitCode = run(command, { cwd: buildDir, env });
  const hostWallNs = Number(process.hrtime.bigint() - hostStart);
  if (exitCode !== 0) process.exit(exitCode);

  const imageShaAfter = sha256(imagePath);
  const hostShaAfter = sha256(hostPath);
  if (imageShaBefore !== imageShaAfter || hostShaBefore !== hostShaAfter) fail("build outputs changed during the hardware run", 75);
  mkdirSync(buildDir, { recursive: true });
  const temporary = join(buildDir, `.run.json.${process.pid}.${randomUUID()}`);
  try {
    writeFileSync(temporary, `${JSON.stringify({ exitCode: 0, imageSha256: imageShaBefore, hostSha256: hostShaBefore, host_wall_ns: hostWallNs })}\n`, { flag: "wx" });
    renameSync(temporary, runJson);
  } finally {
    rmSync(temporary, { force: true });
  }
}

function validateBuiltProtectIdentity(sample: Sample, buildDir: string): void {
  const readyPath = join(buildDir, "ready.json");
  const cachePath = join(buildDir, "CMakeCache.txt");
  if (!existsSync(readyPath) || !existsSync(cachePath)) fail(`protect build identity is incomplete: ${buildDir}`, 66);
  let ready: Record<string, unknown>;
  try { ready = JSON.parse(readFileSync(readyPath, "utf8")) as Record<string, unknown>; }
  catch { fail(`protect ready identity is not valid JSON: ${readyPath}`, 66); }
  const cache = readFileSync(cachePath, "utf8").split("\n");
  const policy = sample.mode === "protect-naive" ? "naive" : "dynamic";
  const cachedPolicy = cache.find((line) => line.startsWith("ATFIELD_WORKSET_POLICY:"));
  if (!cachedPolicy?.endsWith(`=${policy}`)) fail(`protect build workset policy mismatch: expected ${policy}`, 66);
  const expectedPath = sample.mode === "protect-naive" ? join(buildDir, "workset.json") : frozenWorkset(sample);
  const expectedSchema = sample.mode === "protect-naive" ? "atfield-workset-v1" : "atfield-workset-v2";
  if (ready!.workset !== expectedPath || ready!.workset_schema !== expectedSchema) {
    fail(`protect ready identity does not match ${policy} workset at ${expectedPath}`, 66);
  }
  if (!existsSync(expectedPath) || typeof ready!.workset_sha256 !== "string" || sha256(expectedPath) !== ready!.workset_sha256) {
    fail(`protect workset hash does not match ready identity: ${expectedPath}`, 66);
  }
  const cacheWorkset = cache.find((line) => line.startsWith("ATFIELD_FROZEN_WORKSET:")) ?? "";
  if (sample.mode === "protect" && !cacheWorkset.endsWith(`=${expectedPath}`)) fail(`protect CMakeCache frozen workset mismatch: ${expectedPath}`, 66);
  if (sample.mode === "protect-naive" && !cacheWorkset.endsWith("=")) fail("protect-naive CMakeCache must not use a frozen workset", 66);
  const signedPath = join(buildDir, "enclave.signed.so");
  if (typeof ready!.signed_final_elf_sha256 !== "string" || !existsSync(signedPath) || sha256(signedPath) !== ready!.signed_final_elf_sha256) {
    fail("protect signed image does not match ready identity", 66);
  }
}

function main(): void {
  const sample = parseArgs(process.argv.slice(2));
  if (sample.action === "build" || sample.action === "profile") buildSample(sample);
  else runSample(sample);
}

if (import.meta.main) main();
