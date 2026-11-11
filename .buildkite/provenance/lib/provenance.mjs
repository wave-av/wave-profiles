// Shared provenance primitives: canonical JSON, digest, repo normalization.
// Dependency-free (node stdlib only). No secret values ever flow through here —
// names only, and names must match the allowlist pattern before emission.

import { createHash } from 'node:crypto';

/** Secret-name allowlist: UPPER_SNAKE only. Anything else fails closed. */
export const SECRET_NAME_RE = /^[A-Z][A-Z0-9_]*$/;

/** Full-length hex SHAs only — no short SHAs in provenance. */
export const SHA1_RE = /^[0-9a-f]{40}$/;
export const SHA256_RE = /^[0-9a-f]{64}$/;

/** Canonical JSON: recursively sorted keys, no whitespace. */
export function canonicalize(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  const keys = Object.keys(value).sort();
  const parts = keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k])}`);
  return `{${parts.join(',')}}`;
}

export function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

/**
 * Digest of a provenance document: sha256 over the canonical form of the
 * document with the `digest` field removed. Unsigned-but-hashed: WAVE-26504
 * Q4 signs this digest; v1 only binds the fields together.
 */
export function digestProvenance(doc) {
  const { digest: _ignored, ...rest } = doc;
  return `sha256:${sha256Hex(canonicalize(rest))}`;
}

/** Verify the embedded digest. Returns { ok, expected, actual }. */
export function verifyDigest(doc) {
  const expected = digestProvenance(doc);
  return { ok: doc.digest === expected, expected, actual: doc.digest };
}

/**
 * Normalize a repo URL for fork comparison: lowercase, trim whitespace,
 * convert scp-style `git@host:org/repo` to https form, strip trailing
 * `.git` and `/`. Deliberately dumb — anything unparseable fails closed
 * at the comparison site (treated as distinct repos).
 */
export function normalizeRepoUrl(url) {
  let u = String(url ?? '').trim().toLowerCase();
  const scp = u.match(/^git@([^:]+):(.+)$/);
  if (scp) u = `https://${scp[1]}/${scp[2]}`;
  u = u.replace(/\/+$/, '');
  if (u.endsWith('.git')) u = u.slice(0, -4);
  return u;
}

/** Recompute fork-ness from repo URLs. Never trusts any claimed bit. */
export function isForkBuild(headRepo, baseRepo) {
  const head = normalizeRepoUrl(headRepo);
  const base = normalizeRepoUrl(baseRepo);
  if (!head || !base) return true; // unparseable endpoints: fail closed = fork
  return head !== base;
}
