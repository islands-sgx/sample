import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const PAGE = 4096;
const anchorSamples = ["curve25519-donna", "fiat-p384", "yescrypt", "sqlite"];
const realSamples = ["qe3", "ehsm", "sgxwallet", "signal-cds"];
const wrapper = Buffer.from([0x0f, 0x1f, 0x80, 0xc3, 0, 0, 0]);
const hash = (data: Buffer) => createHash("sha256").update(data).digest("hex");
const page = (n: number) => Math.floor(n / PAGE) * PAGE;
const hex = (n: number) => `0x${n.toString(16)}`;

function requireThat(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}

type Section = {
  name: string; type: number; flags: number; address: number; offset: number;
  size: number; link: number; entrySize: number;
};
type Segment = { address: number; offset: number; fileSize: number; memorySize: number };

export type AnchorFact = {
  payload: bigint; functionOrdinal: bigint; ordinal: bigint;
  kind: 1 | 2; address: number;
};

export class Elf {
  sections: Section[] = [];
  loadable: Segment[] = [];
  executable: Segment[] = [];
  anchors = new Map<string, AnchorFact>();

  constructor(readonly bytes: Buffer) {
    this.range(0, 64);
    requireThat(bytes.subarray(0, 7).equals(Buffer.from([127, 69, 76, 70, 2, 1, 1])),
      "expected little-endian ELF64");
    requireThat(this.u16(18) === 62 && [2, 3].includes(this.u16(16)),
      "expected linked x86-64 ELF");
    const phoff = this.u64(32), shoff = this.u64(40);
    const phsize = this.u16(54), phcount = this.u16(56);
    const shsize = this.u16(58), shcount = this.u16(60), namesIndex = this.u16(62);
    requireThat(phsize === 56 && shsize === 64 && shcount > 0 && namesIndex < shcount,
      "unsupported ELF table layout");
    this.range(phoff, phsize * phcount);
    this.range(shoff, shsize * shcount);
    for (let i = 0; i < phcount; i++) {
      const p = phoff + i * phsize;
      if (this.u32(p) !== 1) continue;
      const flags = this.u32(p + 4);
      const segment = {
        offset: this.u64(p + 8), address: this.u64(p + 16),
        fileSize: this.u64(p + 32), memorySize: this.u64(p + 40),
      };
      requireThat(segment.fileSize <= segment.memorySize, "invalid load segment");
      this.range(segment.offset, segment.fileSize);
      requireThat(Number.isSafeInteger(segment.address + segment.memorySize),
        "load segment address overflow");
      this.loadable.push(segment);
      if (!(flags & 1)) continue;
      requireThat(!(flags & 2), "writable executable load segment");
      this.executable.push(segment);
    }
    requireThat(this.executable.length > 0, "no executable load segment");
    const stringHeader = shoff + namesIndex * shsize;
    const namesOffset = this.u64(stringHeader + 24), namesSize = this.u64(stringHeader + 32);
    this.range(namesOffset, namesSize);
    for (let i = 0; i < shcount; i++) {
      const s = shoff + i * shsize;
      const section = {
        name: this.string(namesOffset, namesSize, this.u32(s)),
        type: this.u32(s + 4), flags: this.u64(s + 8), address: this.u64(s + 16), offset: this.u64(s + 24),
        size: this.u64(s + 32), link: this.u32(s + 40), entrySize: this.u64(s + 56),
      };
      if (section.type !== 8) this.range(section.offset, section.size);
      this.sections.push(section);
    }
    requireThat(!this.sections.some(s => s.name === ".note.atfield.anchors"),
      "legacy ATField note; rebuild with the symbol-only toolchain");
    for (const s of this.sections.filter(s => s.type === 2 || s.type === 11)) {
      requireThat(s.entrySize === 24 && s.size % 24 === 0, "invalid symbol table");
      const strings = this.sections[s.link];
      requireThat(strings?.type === 3, "missing symbol string table");
      for (let p = s.offset; p < s.offset + s.size; p += 24) {
        const name = this.string(strings.offset, strings.size, this.u32(p));
        requireThat(!name.startsWith("__atfield_anchor_") &&
          !name.startsWith("__atfield_native_anchor_"), "legacy ATField anchor symbol");
        if (!name.startsWith("__atf_")) continue;
        const match = /^__atf_([nc])_((?:0|[1-9a-f][0-9a-f]{0,15}))_((?:0|[1-9a-f][0-9a-f]{0,15}))_((?:0|[1-9a-f][0-9a-f]{0,15}))$/.exec(name);
        requireThat(match, "invalid ATField anchor name: " + name);
        const section = this.sections[this.u16(p + 6)];
        const address = this.u64(p + 8), info = this.bytes[p + 4];
        requireThat(section && (section.flags & 6) === 6 &&
          address >= section.address && address - section.address < section.size,
          "anchor is outside its executable section: " + name);
        requireThat((info & 15) === 0 && (info >> 4) <= 1 &&
          (this.bytes[p + 5] & 3) === 2 && this.u64(p + 16) === 0,
          "invalid ATField anchor symbol attributes: " + name);
        const payload = BigInt("0x" + match[2]);
        const functionOrdinal = BigInt("0x" + match[3]);
        const ordinal = BigInt("0x" + match[4]);
        const identity = match.slice(2).join("_"), kind = match[1] === "n" ? 1 : 2;
        const previous = this.anchors.get(identity);
        requireThat(previous === undefined ||
          (previous.address === address && previous.kind === kind),
          "conflicting ATField anchor identity: " + identity);
        this.anchors.set(identity, { payload, functionOrdinal, ordinal, kind, address });
      }
    }
    // Final-image candidates are stable only when loading cannot rewrite text.
    const widths = new Map([[0, 0], [1, 8], [2, 4], [6, 8], [7, 8], [8, 8],
      [10, 4], [11, 4], [16, 8], [17, 8], [18, 8], [37, 8]]);
    const xpages = this.pages();
    for (const s of this.sections.filter(s => (s.flags & 2) && [4, 9, 19].includes(s.type))) {
      requireThat(s.type !== 19, "RELR relocations are not supported");
      const size = s.type === 4 ? 24 : 16;
      requireThat(s.entrySize === size && s.size % size === 0, "invalid relocation table");
      for (let p = s.offset; p < s.offset + s.size; p += size) {
        const address = this.u64(p), type = this.u32(p + 8);
        const width = widths.get(type);
        requireThat(width !== undefined, `unsupported runtime relocation ${type}`);
        if (!width) continue;
        requireThat(!xpages.has(page(address)) && !xpages.has(page(address + width - 1)),
          `runtime relocation can rewrite executable page at ${hex(address)}`);
      }
    }
  }

  range(offset: number, length: number) {
    requireThat(Number.isSafeInteger(offset) && Number.isSafeInteger(length) &&
      offset >= 0 && length >= 0 && offset <= this.bytes.length &&
      length <= this.bytes.length - offset, "ELF range outside file");
  }
  u16(p: number) { this.range(p, 2); return this.bytes.readUInt16LE(p); }
  u32(p: number) { this.range(p, 4); return this.bytes.readUInt32LE(p); }
  u64(p: number) {
    this.range(p, 8);
    const value = this.bytes.readBigUInt64LE(p);
    requireThat(value <= BigInt(Number.MAX_SAFE_INTEGER), "ELF integer too large");
    return Number(value);
  }
  string(offset: number, size: number, index: number) {
    requireThat(index < size, "string index outside table");
    const end = this.bytes.indexOf(0, offset + index);
    requireThat(end >= 0 && end < offset + size, "unterminated ELF string");
    return this.bytes.toString("utf8", offset + index, end);
  }
  pages() {
    const result = new Set<number>();
    for (const s of this.executable) {
      if (!s.memorySize) continue;
      for (let p = page(s.address); p < s.address + s.memorySize; p += PAGE) result.add(p);
    }
    return result;
  }
  at(address: number, size: number) {
    const s = this.executable.find(s =>
      address >= s.address && address - s.address + size <= s.fileSize);
    requireThat(s, `address ${hex(address)} is not executable file-backed data`);
    return this.bytes.subarray(s.offset + address - s.address,
      s.offset + address - s.address + size);
  }
  candidates() {
    const result = new Set<number>();
    for (const s of this.executable) {
      for (let i = 0; i < s.fileSize; i++) {
        if (this.bytes[s.offset + i] === 0xc3) result.add(s.address + i);
      }
    }
    return result;
  }

}

export function inspect(bytes: Buffer) {
  const elf = new Elf(bytes), pages = elf.pages(), candidates = elf.candidates();
  const candidatePages = new Set([...candidates].map(page));
  const named = new Map<number, Set<1 | 2>>();
  for (const { address, kind } of elf.anchors.values()) {
    requireThat(elf.at(address, 1)[0] === 0xc3, "anchor byte is not C3: " + hex(address));
    if (kind === 2) requireThat(elf.at(address - 3, 7).equals(wrapper),
      "constructed anchor wrapper differs: " + hex(address));
    // ICF may alias distinct identities, including the two categories.
    const kinds = named.get(address) ?? new Set<1 | 2>();
    kinds.add(kind);
    named.set(address, kinds);
  }
  const namedPages = new Set([...named.keys()].map(page));
  const textBytes = elf.sections
    .filter(s => s.name === ".text")
    .reduce((sum, s) => sum + s.size, 0);
  return {
    elfBytes: bytes.length,
    textBytes,
    loadableFileBytes: elf.loadable.reduce((sum, s) => sum + s.fileSize, 0),
    loadableMemoryBytes: elf.loadable.reduce((sum, s) => sum + s.memorySize, 0),
    executableFileBytes: elf.executable.reduce((sum, s) => sum + s.fileSize, 0),
    executablePages: pages.size,
    stableC3Candidates: candidates.size,
    pagesWithC3Candidate: candidatePages.size,
    pagesWithoutC3Candidate: [...pages].filter(p => !candidatePages.has(p)).map(hex),
    namedNaturalAnchors: [...named.values()].filter(k => k.has(1)).length,
    namedConstructedAnchors: [...named.values()].filter(k => k.has(2)).length,
    pagesWithNamedAnchor: namedPages.size,
    pagesWithoutNamedAnchor: [...pages].filter(p => !namedPages.has(p)).map(hex),
  };
}

export function validateMode(
  name: string,
  mode: "raw" | "anchor",
  report: Pick<
    ReturnType<typeof inspect>,
    | "pagesWithoutC3Candidate"
    | "pagesWithoutNamedAnchor"
    | "namedNaturalAnchors"
    | "namedConstructedAnchors"
  >,
) {
  if (mode === "raw") {
    requireThat(
      report.namedNaturalAnchors === 0 && report.namedConstructedAnchors === 0,
      `${name}/raw: unexpected named ATField anchors in raw baseline`,
    );
    return;
  }
  requireThat(
    report.pagesWithoutC3Candidate.length === 0,
    `${name}/anchor: executable pages missing stable C3 candidate: ${report.pagesWithoutC3Candidate.join(", ")}`,
  );
  requireThat(
    report.pagesWithoutNamedAnchor.length === 0,
    `${name}/anchor: executable pages missing named anchor symbol: ${report.pagesWithoutNamedAnchor.join(", ")}`,
  );
}

export function render(rows: readonly {
  name: string; raw: ReturnType<typeof inspect> & { signedImageBytes: number }; anchor: ReturnType<typeof inspect> & { signedImageBytes: number };
}[]) {
  const header =
    "| Sample | Mode | HW | Analysis ELF Bytes | Signed ELF Bytes | Text Bytes | Load Bytes | X Bytes | X Pages | C3-Missing Pages | Named-Missing Pages | Named Natural | Constructed |\n" +
    "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n";
  return header + rows.flatMap(row =>
    ([["raw", row.raw], ["anchor", row.anchor]] as const).map(([mode, r]) =>
      `| ${row.name} | ${mode} | PASS | ${r.elfBytes} | ${r.signedImageBytes} | ${r.textBytes} | ${r.loadableFileBytes} | ${r.executableFileBytes} | ${r.executablePages} | ` +
      `${r.pagesWithoutC3Candidate.length} | ${r.pagesWithoutNamedAnchor.length} | ${r.namedNaturalAnchors} | ${r.namedConstructedAnchors} |`)).join("\n");
}

async function inspectPair(root: string, group: "anchor" | "real", name: string) {
  const pair = [];
  for (const mode of ["raw", "anchor"] as const) {
    const dir = resolve(root, group, name, mode);
    const [bytes, signed, host, commands, runBytes] = await Promise.all(
      ["enclave.so", "enclave.signed.so", "host", "compile_commands.json", "run.json"]
        .map(file => readFile(resolve(dir, file))));
    const run = JSON.parse(runBytes.toString());
    requireThat(run.exitCode === 0 && run.imageSha256 === hash(signed) &&
      run.hostSha256 === hash(host), `${name}/${mode}: missing successful current-artifact run`);
    const image = new Elf(bytes), signedImage = new Elf(signed);
    requireThat(image.executable.length === signedImage.executable.length,
      `${name}/${mode}: signing changed executable mappings`);
    for (let i = 0; i < image.executable.length; i++) {
      const a = image.executable[i], b = signedImage.executable[i];
      requireThat(a.address === b.address && a.fileSize === b.fileSize &&
        a.memorySize === b.memorySize && image.at(a.address, a.fileSize)
          .equals(signedImage.at(b.address, b.fileSize)), "signing changed executable bytes");
    }
    const report = inspect(bytes);
    validateMode(`${group}/${name}`, mode, report);
    pair.push({ mode, signedImageBytes: signed.length, imageSha256: hash(bytes), signedImageSha256: hash(signed),
      compileCommandsSha256: hash(commands), ...report });
  }
  const [raw, anchor] = pair;
  return {
    name,
    raw,
    anchor,
    elfByteDelta: anchor.elfBytes - raw.elfBytes,
    textByteDelta: anchor.textBytes - raw.textBytes,
    loadableByteDelta: anchor.loadableFileBytes - raw.loadableFileBytes,
    executableByteDelta: anchor.executableFileBytes - raw.executableFileBytes,
    executablePageDelta: anchor.executablePages - raw.executablePages,
  };
}

async function main() {
  const root = resolve(process.argv[2] ?? "build");
  const rows = [];
  for (const name of anchorSamples) {
    rows.push(await inspectPair(root, "anchor", name));
  }
  const realReady = realSamples.every(name =>
    (["raw", "anchor"] as const).every(mode =>
      existsSync(resolve(root, "real", name, mode, "run.json"))));
  if (realReady) {
    for (const name of realSamples) {
      rows.push(await inspectPair(root, "real", name));
    }
  }
  const table = render(rows);
  await mkdir(resolve(root, "anchor"), { recursive: true });
  await writeFile(resolve(root, "anchor", "results.json"), JSON.stringify({ pageBytes: PAGE, samples: rows }, null, 2) + "\n");
  await writeFile(resolve(root, "anchor", "comparison.md"), table + "\n");
  console.log(table);
}

if (import.meta.main) await main();
