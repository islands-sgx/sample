import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { generateReport, validateCurrentRun } from "./anchor-report.ts";

const temporary = mkdtempSync(join(tmpdir(), "anchor-report-"));
afterAll(() => rmSync(temporary, { recursive: true, force: true }));

const digest = (data: string | Buffer) => createHash("sha256").update(data).digest("hex");
const metrics = {
  elfBytes: 1, textBytes: 1, loadableFileBytes: 1, loadableMemoryBytes: 1,
  executableFileBytes: 1, executablePages: 1, stableC3Candidates: 1,
  pagesWithC3Candidate: 1, pagesWithoutC3Candidate: [] as string[],
  namedNaturalAnchors: 1, namedConstructedAnchors: 0, pagesWithNamedAnchor: 1,
  pagesWithoutNamedAnchor: [] as string[],
};
function fakePair(name: string) {
  return {
    name, raw: { ...metrics, signedImageBytes: 1 }, anchor: { ...metrics, signedImageBytes: 1 },
    elfByteDelta: 0, textByteDelta: 0, loadableByteDelta: 0,
    executableByteDelta: 0, executablePageDelta: 0,
  };
}

test("anchor-only report ignores stale and partial bench run caches", async () => {
  const root = join(temporary, "anchor-only");
  mkdirSync(join(root, "bench", "application", "qe3", "raw"), { recursive: true });
  mkdirSync(join(root, "bench", "application", "qe3", "anchor"), { recursive: true });
  writeFileSync(join(root, "bench", "application", "qe3", "raw", "run.json"), JSON.stringify({
    exitCode: 0, imageSha256: "stale", hostSha256: "stale",
  }));
  writeFileSync(join(root, "bench", "application", "qe3", "anchor", "run.json"), "{partial");
  const calls: string[] = [];
  const inspectSample = async (_root: string, group: "anchor" | "bench/micro" | "bench/application", name: string) => {
    calls.push(group + "/" + name);
    return fakePair(name);
  };

  const { rows, table } = await generateReport(root, false, inspectSample);

  expect(calls).toEqual([
    "anchor/curve25519-donna", "anchor/fiat-p384", "anchor/yescrypt", "anchor/sqlite",
  ]);
  expect(rows).toHaveLength(4);
  expect(table).not.toContain("| qe3 |");
});

test("explicit bench inclusion reaches both scales and propagates stale current-artifact failure", async () => {
  const root = join(temporary, "include-bench");
  const calls: string[] = [];
  const inspectSample = async (_root: string, group: "anchor" | "bench/micro" | "bench/application", name: string) => {
    calls.push(group + "/" + name);
    if (group === "bench/application" && name === "qe3") {
      throw new Error("qe3/raw: missing successful current-artifact run");
    }
    return fakePair(name);
  };

  await expect(generateReport(root, true, inspectSample))
    .rejects.toThrow("qe3/raw: missing successful current-artifact run");
  expect(calls.slice(0, 4)).toEqual([
    "anchor/curve25519-donna", "anchor/fiat-p384", "anchor/yescrypt", "anchor/sqlite",
  ]);
  expect(calls.slice(4, 6)).toEqual([
    "bench/micro/yescrypt-kdf-rw", "bench/micro/wolfssl-pbkdf2-sha256",
  ]);
  expect(calls).toContain("bench/application/qe3");
});

test("run validation rejects stale image and host hashes", () => {
  const signed = Buffer.from("current signed image"), host = Buffer.from("current host");
  const stale = Buffer.from(JSON.stringify({
    exitCode: 0, imageSha256: digest("old image"), hostSha256: digest("old host"),
  }));
  expect(() => validateCurrentRun("qe3", "raw", stale, signed, host))
    .toThrow("qe3/raw: missing successful current-artifact run");
  const current = Buffer.from(JSON.stringify({
    exitCode: 0, imageSha256: digest(signed), hostSha256: digest(host),
  }));
  expect(() => validateCurrentRun("qe3", "raw", current, signed, host)).not.toThrow();
});
