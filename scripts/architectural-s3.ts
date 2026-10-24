type Row = Record<string, unknown>;
const row = (value: unknown): value is Row => value !== null && typeof value === "object" && !Array.isArray(value);
const pages = (value: unknown): Row[] => row(value) && Array.isArray(value.page_effects) && value.page_effects.every(row)
  ? value.page_effects : [];
const key = (field: unknown, page: unknown, a: unknown, d: unknown): string =>
  JSON.stringify([field, page, a, d]);

export function assertDeclaredArchitectureS3(
  summary: Row,
  traceText: string,
  declaration: unknown,
  signedMeasurementElfSha256: string,
): number {
  if (!row(declaration) || declaration.schema !== "atfield-architectural-s3-v1" ||
      declaration.signed_measurement_final_elf_sha256 !== signedMeasurementElfSha256 ||
      !Array.isArray(declaration.effects) || declaration.effects.length === 0) {
    throw new Error("architectural S3 declaration is missing, malformed, or bound to another Final");
  }
  const allowed = new Set<string>();
  for (const effect of declaration.effects) {
    if (!row(effect) || typeof effect.field_id !== "string" ||
        typeof effect.page_rva !== "string" || !/^0x[0-9a-f]+$/.test(effect.page_rva) ||
        typeof effect.a !== "boolean" || typeof effect.d !== "boolean" ||
        (effect.instruction !== "EGETKEY" && effect.instruction !== "EREPORT")) {
      throw new Error("invalid architectural S3 effect declaration");
    }
    const identity = key(effect.field_id, effect.page_rva, effect.a, effect.d);
    if (allowed.has(identity)) throw new Error("duplicate architectural S3 effect declaration");
    allowed.add(identity);
  }

  const validation = summary.final_v2_validation;
  if (!row(validation) || validation.verdict !== "FAIL" ||
      validation.final_v2_verification_failure_count !== 0 ||
      summary.completion !== "complete" || summary.measurement_complete !== true ||
      summary.exit_code !== 0 || summary.invalid_ecall_count !== 0 ||
      !Array.isArray(summary.s3_body_page_observations) ||
      summary.s3_body_page_observations.length === 0) {
    throw new Error("architectural S3 declaration cannot cover another Final failure");
  }

  const observed = new Set<string>();
  for (const line of traceText.split(/\r?\n/)) {
    if (!line) continue;
    const call: unknown = JSON.parse(line);
    if (!row(call) || call.record_type !== "ecall") continue;
    if (!Array.isArray(call.fields)) throw new Error("Final trace has no Field records");
    for (const field of call.fields) {
      if (!row(field) || typeof field.field_id !== "string" || !row(field.phases)) {
        throw new Error("Final trace has malformed Field phases");
      }
      const s2 = pages(field.phases.S2_PRETOUCH);
      for (const effect of pages(field.phases.S3_BODY)) {
        const identity = key(field.field_id, effect.rva, effect.a, effect.d);
        if (!allowed.has(identity)) throw new Error("undeclared S3 page effect: " + identity);
        if (!s2.some((prior) => prior.rva === effect.rva && prior.a === true &&
            (effect.d !== true || prior.d === true))) {
          throw new Error("declared architectural S3 page was not made ready in the same call: " + identity);
        }
        observed.add(identity);
      }
    }
  }
  const reported = new Set<string>();
  for (const effect of summary.s3_body_page_observations) {
    if (!row(effect)) throw new Error("malformed S3 summary observation");
    reported.add(key(effect.field_id, effect.page_rva, effect.a, effect.d));
  }
  if (validation.observed_page_count !== reported.size || reported.size !== observed.size ||
      [...reported].some((identity) => !observed.has(identity))) {
    throw new Error("Final trace and S3 summary disagree");
  }
  return observed.size;
}
