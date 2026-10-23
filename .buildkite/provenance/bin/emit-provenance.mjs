#!/usr/bin/env node
// emit-provenance — build a provenance.json for one Buildkite run (WAVE-26503 O1).
//
// Collects pipeline/build identity from BUILDKITE_* env, per-step facts from a
// steps manifest, guard outputs from a guards manifest, hashes each executed
// script from the checkout, binds it all with a digest, uploads the artifact,
// and optionally mirrors it to the sweep corpus.
//
// Secrets are NAME-ONLY: names arrive via --injected/--withheld (or env) and
// must match ^[A-Z][A-Z0-9_]*$. Anything else-shaped fails closed (exit 2) so
// a value can never be smuggled into the artifact. This script never reads a
// secret value from anywhere.
//
// Usage:
//   node bin/emit-provenance.mjs --repo-dir <checkout> --steps steps.json \
//     --guards guards.json --base-rev <40-hex> --out provenance.json \
//     [--injected step:NAME,...] [--withheld step:NAME:reason,...] \
//     [--mirror-dir <dir>] [--no-upload]
//
// steps.json:  [{ "key": "...", "queue": "...", "command": "<script path>", "exit": 0 }]
//              (index defaults to array order; command must be one script path)
// guards.json: [{ "key": "...", "verdict": "pass"|"fail", "detail": "..." }]

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  SECRET_NAME_RE,
  SHA1_RE,
  digestProvenance,
  isForkBuild,
} from '../lib/provenance.mjs';

const VERSION = '0.1.0';

function fail(msg) {
  console.error(`emit-provenance: ${msg}`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-upload') { out.noUpload = true; continue; }
    if (!a.startsWith('--') || i + 1 >= argv.length) fail(`bad argument: ${a}`);
    out[a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
  }
  return out;
}

function readJson(path, what) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    fail(`cannot read ${what} ${path}: ${err.message}`);
  }
}

function checkSecretName(name, where) {
  if (!SECRET_NAME_RE.test(name)) {
    fail(`refusing to emit ${where}: ${JSON.stringify(name)} is not a UPPER_SNAKE secret NAME — value smuggling fails closed`);
  }
}

function parsePairs(raw, what, wantReason) {
  if (!raw) return [];
  return raw.split(',').filter(Boolean).map((entry) => {
    const parts = entry.split(':');
    const [stepKey, name, reason] = wantReason
      ? [parts[0], parts[1], parts.slice(2).join(':')]
      : [parts[0], parts[1]];
    if (!stepKey || !name || (wantReason && !reason)) fail(`bad --${what} entry: ${entry}`);
    if (wantReason && /[A-Z0-9_]{16,}/.test(reason) && /token|secret|key|passwd/i.test(reason)) {
      fail(`refusing to emit --${what} entry with value-shaped reason: ${entry}`);
    }
    checkSecretName(name, `--${what} entry ${entry}`);
    return wantReason ? { step_key: stepKey, name, reason } : { step_key: stepKey, name };
  });
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  for (const flag of ['repoDir', 'steps', 'guards', 'baseRev', 'out']) {
    if (!args[flag]) fail(`missing required --${flag.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`);
  }
  const repoDir = resolve(args.repoDir);
  if (!SHA1_RE.test(args.baseRev)) fail(`--base-rev must be a full 40-hex SHA, got: ${args.baseRev}`);

  const env = process.env;
  const slug = env.BUILDKITE_PIPELINE_SLUG;
  const buildNumber = Number.parseInt(env.BUILDKITE_BUILD_NUMBER ?? '', 10);
  const buildUuid = env.BUILDKITE_BUILD_ID;
  const branch = env.BUILDKITE_BRANCH;
  const commit = env.BUILDKITE_COMMIT;
  const headRepo = env.BUILDKITE_PULL_REQUEST_REPO || env.BUILDKITE_REPO;
  const baseRepo = env.BUILDKITE_REPO;
  for (const [name, value] of Object.entries({ slug, buildUuid, branch, commit, headRepo, baseRepo })) {
    if (!value) fail(`missing required env: BUILDKITE_${name === 'slug' ? 'PIPELINE_SLUG' : name.replace(/([A-Z])/g, '_$1').toUpperCase()}`);
  }
  if (!Number.isInteger(buildNumber) || buildNumber < 1) fail('BUILDKITE_BUILD_NUMBER must be a positive integer');
  if (!SHA1_RE.test(commit)) fail(`BUILDKITE_COMMIT must be a full 40-hex SHA, got: ${commit}`);

  const rawSteps = readJson(args.steps, 'steps manifest');
  if (!Array.isArray(rawSteps) || rawSteps.length === 0) fail('steps manifest must be a non-empty array');
  const steps = rawSteps.map((s, i) => {
    if (!s || typeof s !== 'object') fail(`steps[${i}] must be an object`);
    const { key, queue, command } = s;
    const exit = Number.parseInt(String(s.exit), 10);
    if (!key || !queue || !command) fail(`steps[${i}] needs key, queue, command`);
    if (!Number.isInteger(exit)) fail(`steps[${i}] needs an integer exit status`);
    if (/\s/.test(command)) fail(`steps[${i}].command must be exactly one script path (no args), got: ${command}`);
    const scriptPath = join(repoDir, command);
    if (!existsSync(scriptPath)) fail(`steps[${i}].command not found in checkout: ${command}`);
    return { index: i, key, queue, command, script_sha256: sha256File(scriptPath), exit };
  });
  const seenKeys = new Set();
  for (const s of steps) {
    if (seenKeys.has(s.key)) fail(`duplicate step key in manifest: ${s.key}`);
    seenKeys.add(s.key);
  }

  const rawGuards = readJson(args.guards, 'guards manifest');
  if (!Array.isArray(rawGuards)) fail('guards manifest must be an array');
  const guards = rawGuards.map((g, i) => {
    if (!g || typeof g !== 'object' || !g.key) fail(`guards[${i}] needs a key`);
    if (g.verdict !== 'pass' && g.verdict !== 'fail') fail(`guards[${i}] verdict must be pass|fail`);
    const entry = { key: g.key, verdict: g.verdict };
    if (g.detail) entry.detail = String(g.detail);
    return entry;
  });

  const stepKeys = new Set(steps.map((s) => s.key));
  const injected = parsePairs(args.injected || env.PROVENANCE_INJECTED, 'injected', false);
  const withheld = parsePairs(args.withheld || env.PROVENANCE_WITHHELD, 'withheld', true);
  for (const rec of [...injected, ...withheld]) {
    if (!stepKeys.has(rec.step_key)) fail(`secret record for unknown step key: ${rec.step_key}`);
  }

  const doc = {
    schema: 'wave-av/build-provenance/v1',
    pipeline: { slug, ...(env.BUILDKITE_PIPELINE_ID ? { uuid: env.BUILDKITE_PIPELINE_ID } : {}) },
    build: {
      number: buildNumber,
      uuid: buildUuid,
      ...(env.BUILDKITE_BUILD_URL ? { url: env.BUILDKITE_BUILD_URL } : {}),
      branch,
      commit,
    },
    base_rev: args.baseRev,
    pr: {
      ...(env.BUILDKITE_PULL_REQUEST && env.BUILDKITE_PULL_REQUEST !== 'false'
        ? { number: env.BUILDKITE_PULL_REQUEST } : {}),
      head_repo: headRepo,
      head_sha: commit,
      head_ref: branch,
      base_repo: baseRepo,
      base_ref: env.BUILDKITE_PULL_REQUEST_BASE_BRANCH || branch,
      is_fork_claimed: isForkBuild(headRepo, baseRepo),
    },
    steps,
    guards,
    secrets: { injected, withheld },
    emitter: { name: 'build-provenance/emit-provenance', version: VERSION, emitted_at: new Date().toISOString() },
    digest: '',
  };
  doc.digest = digestProvenance(doc);

  const outPath = resolve(args.out);
  writeFileSync(outPath, `${JSON.stringify(doc, null, 2)}\n`);
  console.log(`wrote ${outPath} digest=${doc.digest}`);

  if (args.mirrorDir) {
    mkdirSync(args.mirrorDir, { recursive: true });
    const mirrorPath = join(resolve(args.mirrorDir), `provenance-${slug}-${buildNumber}.json`);
    copyFileSync(outPath, mirrorPath);
    console.log(`mirrored ${mirrorPath}`);
  }

  if (!args.noUpload) {
    try {
      execFileSync('buildkite-agent', ['artifact', 'upload', outPath], { stdio: 'inherit' });
    } catch (err) {
      if (env.BUILDKITE === 'true') fail(`artifact upload failed on BK: ${err.message}`);
      console.error('warning: buildkite-agent upload skipped (not on BK)');
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
