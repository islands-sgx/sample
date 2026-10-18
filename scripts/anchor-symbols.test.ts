import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { Elf, inspect, validateMode } from "./anchor-report.ts";

const compiler = process.env.ATFIELD_LLC, linker = process.env.ATFIELD_LLD;
if (!compiler || !linker) throw new Error("run in a sample Nix shell with ATFIELD_LLC and ATFIELD_LLD");
const bin = dirname(compiler), root = resolve(import.meta.dir, "..");
const temporary = mkdtempSync(join(tmpdir(), "anchor-symbols-"));
afterAll(() => rmSync(temporary, { recursive: true, force: true }));
function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) throw new Error(command + ": " + result.stderr);
  return result.stdout;
}
function assemble(name: string, lines: string[]) {
  const input = join(temporary, name + ".s"), output = join(temporary, name + ".o");
  writeFileSync(input, lines.join("\n") + "\n");
  run(join(bin, "llvm-mc"), ["-triple=x86_64-unknown-linux-gnu", "-filetype=obj", input, "-o", output]);
  return output;
}
function link(name: string, object: string, extra: string[] = []) {
  const output = join(temporary, name);
  run(linker!, ["--entry=_start", "--gc-sections", ...extra, object, "-o", output]);
  return output;
}
function facts(file: string) { return [...new Elf(readFileSync(file)).anchors.entries()]; }
function inject(file: string) {
  run("python3", [join(root, "scripts/inject-native-anchors.py"), file, "18446744073709551615"]);
}
function anchor(name: string) {
  return ".globl " + name + "\n.hidden " + name + "\n" + name + ":";
}
const entry = [".text", ".globl _start", "_start:"];

test("native preserves every C3, relocations, complete IDs and repeatability", () => {
  const object = assemble("native", [...entry, ".byte 0xc3,0xc3",
    ".byte 0x0f,0x1f,0x80,0xc3,0,0,0", "relocated:", ".long 0xc3",
    ".reloc relocated,R_X86_64_32,_start"]);
  const originalText = join(temporary, "original-text");
  run(join(bin, "llvm-objcopy"), ["--dump-section=.text=" + originalText, object]);
  const relocations = () => run(join(bin, "llvm-readelf"), ["-r", object])
    .split("\n").filter(line => /^[0-9a-f]{16}\s/.test(line));
  const originalRelocs = relocations();
  inject(object);
  const once = readFileSync(object);
  inject(object);
  expect(readFileSync(object)).toEqual(once);
  const newText = join(temporary, "new-text");
  run(join(bin, "llvm-objcopy"), ["--dump-section=.text=" + newText, object]);
  expect(readFileSync(newText)).toEqual(readFileSync(originalText));
  expect(relocations()).toEqual(originalRelocs);
  const values = facts(link("native.elf", object)).map(([id, value]) => [id, value.kind]);
  expect(values).toEqual([["ffffffffffffffff_0_0", 1], ["ffffffffffffffff_0_1", 1],
    ["ffffffffffffffff_0_2", 2]]);
  const partial = join(temporary, "partial.o");
  run(join(bin, "llvm-objcopy"), ["--strip-symbol=__atf_n_ffffffffffffffff_0_1", object, partial]);
  const rejected = spawnSync("python3", [join(root, "scripts/inject-native-anchors.py"),
    partial, "18446744073709551615"], { encoding: "utf8" });
  expect(rejected.status).not.toBe(0);
  expect(rejected.stderr).toMatch(/complete expected set/);
});

test("zero-anchor native object is an exact no-op", () => {
  const object = assemble("zero", [...entry, "nop"]), before = readFileSync(object);
  inject(object); inject(object);
  expect(readFileSync(object)).toEqual(before);
  expect(facts(link("zero.elf", object))).toEqual([]);
});

test("LLVM preserves full uint64 IDs and all dense natural anchors", () => {
  const object = assemble("llvm-identity", [...entry,
    ".atfield_function_begin 18446744073709551615,18364758544493064720",
    ".atfield_unit_begin 0,0,1,0", ".byte 0xc3,0xc3,0xc3", ".atfield_function_end"]);
  const values = facts(link("llvm-identity.elf", object));
  expect(values.map(([id]) => id)).toEqual(["ffffffffffffffff_fedcba9876543210_0",
    "ffffffffffffffff_fedcba9876543210_1", "ffffffffffffffff_fedcba9876543210_2"]);
  expect(values[0][1].payload).toBe(0xffffffffffffffffn);
  expect(values[0][1].functionOrdinal).toBe(0xfedcba9876543210n);
});

test("GC discards dead anchor identities with their code", () => {
  const object = assemble("gc", ['.section .text.entry,"ax",@progbits', ".globl _start",
    "_start:", "call live", "ret", '.section .text.live,"ax",@progbits', "live:",
    ".atfield_function_begin 1,0", ".atfield_unit_begin 0,0,1,0", "ret", ".atfield_function_end",
    '.section .text.dead,"ax",@progbits', "dead:", ".atfield_function_begin 2,0",
    ".atfield_unit_begin 0,0,1,0", "ret", ".atfield_function_end"]);
  expect(facts(link("gc.elf", object)).map(([id]) => id)).toEqual(["1_0_0"]);
});

test("ICF retains distinct identities and categories sharing one address", () => {
  const object = assemble("icf", ['.section .text.entry,"ax",@progbits', ".globl _start",
    "_start:", "call first", "call second", "ret", '.section .text.first,"ax",@progbits',
    "first:", ".byte 0x0f,0x1f,0x80", anchor("__atf_n_1_0_0"), ".byte 0xc3,0,0,0", "ret",
    '.section .text.second,"ax",@progbits', "second:", ".byte 0x0f,0x1f,0x80",
    anchor("__atf_c_2_0_0"), ".byte 0xc3,0,0,0", "ret"]);
  const image = link("icf.elf", object, ["--icf=all"]), values = facts(image);
  expect(values.length).toBe(2);
  expect(values[0][1].address).toBe(values[1][1].address);
  const report = inspect(readFileSync(image));
  expect(report.namedNaturalAnchors).toBe(1);
  expect(report.namedConstructedAnchors).toBe(1);
});

test("same identity with a conflicting category fails", () => {
  const object = assemble("conflict", [...entry, ".byte 0x0f,0x1f,0x80",
    anchor("__atf_n_1_0_0"), anchor("__atf_c_1_0_0"), ".byte 0xc3,0,0,0", "ret"]);
  expect(() => facts(link("conflict.elf", object))).toThrow(/conflicting ATField anchor identity/);
});

test("strip keeps explicit facts for extraction; early full strip fails coverage", () => {
  const object = assemble("strip", [...entry, anchor("__atf_n_1_0_0"), "ret"]);
  const image = link("strip.elf", object), original = facts(image);
  const debug = join(temporary, "strip-debug.elf");
  run(join(bin, "llvm-objcopy"), ["--strip-debug", image, debug]);
  expect(facts(debug)).toEqual(original);
  const names = join(temporary, "keep-names.txt"), kept = join(temporary, "strip-kept.elf");
  writeFileSync(names, "__atf_n_1_0_0\n");
  run(join(bin, "llvm-objcopy"), ["--strip-unneeded", "--keep-symbols=" + names, image, kept]);
  expect(facts(kept)).toEqual(original);
  const published = join(temporary, "strip-all.elf");
  run(join(bin, "llvm-objcopy"), ["--strip-all", image, published]);
  expect(facts(published)).toEqual([]);
  expect(() => validateMode("stripped-before-extraction", "anchor",
    inspect(readFileSync(published)))).toThrow(/missing named anchor/);
});

test("malformed names and non-C3 addresses fail", () => {
  const malformed = link("malformed.elf", assemble("malformed", [...entry,
    anchor("__atf_n_01_0_0"), "ret"]));
  expect(() => facts(malformed)).toThrow(/invalid ATField anchor name/);
  const wrong = link("wrong.elf", assemble("wrong", [...entry, anchor("__atf_n_1_0_0"),
    "nop", "ret"]));
  expect(() => inspect(readFileSync(wrong))).toThrow(/anchor byte is not C3/);
});
