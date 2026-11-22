/**
 * @offload/masking
 * Server-side masking checks and leak scanners that mirror the Mac client's on-device masker.
 * m3-01-ingest-batches: the transport leak scan (detectors) and the exclusion rules with the built-in list.
 * See docs/adr/0005-masked-text-only-reaches-models.md and docs/SECURITY_PRIVACY.md section 5.
 */
export { DETECTOR_NAMES, scanForLeak, type DetectorName } from "./detectors.ts";
export { BUILTIN_EXCLUSIONS, EXCLUSION_KINDS, matchExclusion, type ExclusionKind, type ExclusionRule, type ExclusionSubject } from "./exclusions.ts";
