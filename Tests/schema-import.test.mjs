import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readLockedSnapshot, syncArtifacts } from '../Scripts/import-schema.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'codex-schema-authority-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const sdk = join(root, 'sdk');
  mkdirSync(sdk);
  const git = (...args) => execFileSync('git', ['-C', sdk, ...args], { encoding: 'utf8' }).trim();
  git('init', '-q');
  const schemaRoot = join(sdk, 'Vendor/CodexAppServerProtocolSchema');
  const write = (name, value) => {
    const path = join(schemaRoot, name);
    mkdirSync(join(path, '..'), { recursive: true });
    writeFileSync(path, JSON.stringify(value) + '\n');
  };
  write('upstream.lock.json', { upstream: { tag: 'rust-v1.2.3', commit: 'a'.repeat(40) } });
  write('method-adoption.json', {
    schema: 'swift-codex.codex-app-server-method-adoption.v1', upstreamTag: 'rust-v1.2.3',
    adopted: { stable: ['thread/read'], experimental: [] }, excluded: [],
  });
  for (const channel of ['stable', 'experimental']) {
    for (const direction of ['ClientRequest', 'ClientNotification', 'ServerRequest', 'ServerNotification']) {
      write(`${channel}/json/${direction}.json`, {
        oneOf: [{ required: ['method'], properties: { method: { enum: ['thread/read'] } } }],
      });
    }
  }
  git('add', '.');
  git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture SDK authority');
  const revision = git('rev-parse', 'HEAD');
  const pin = { identity: 'swift-codex', location: 'https://github.com/swift-library/swift-codex.git', state: { version: '0.2.2', revision } };
  writeFileSync(join(root, 'Package.resolved'), JSON.stringify({ pins: [pin] }));
  return { root, sdk, revision, write, git, pin };
}

test('derives declarations and adoption from the locked commit despite dirty SDK work', t => {
  const f = fixture(t);
  f.write('method-adoption.json', { unrelated: 'uncommitted work must be preserved' });
  f.write('stable/json/ClientRequest.json', { unrelated: 'dirty schema' });
  const snapshot = readLockedSnapshot(f.root, f.sdk);
  assert.equal(snapshot.receipt.sdk.revision, f.revision);
  assert.equal(snapshot.receipt.codexVersion, '1.2.3');
  assert.deepEqual(JSON.parse(snapshot.artifacts.get('adoption.json')).adopted.stable, ['thread/read']);
  assert.match(readFileSync(join(f.sdk, 'Vendor/CodexAppServerProtocolSchema/method-adoption.json'), 'utf8'), /uncommitted/);
});

test('check detects drift and never rewrites output', t => {
  const f = fixture(t);
  const snapshot = readLockedSnapshot(f.root, f.sdk);
  const output = join(f.root, 'output');
  syncArtifacts(snapshot, output, false);
  syncArtifacts(snapshot, output, true);
  const path = join(output, 'stable/ClientRequest.json');
  writeFileSync(path, 'tampered');
  assert.throws(() => syncArtifacts(snapshot, output, true), /drift/);
  assert.equal(readFileSync(path, 'utf8'), 'tampered');
});

test('missing locked commit never falls back to a moving checkout', t => {
  const f = fixture(t);
  f.pin.state.revision = 'f'.repeat(40);
  writeFileSync(join(f.root, 'Package.resolved'), JSON.stringify({ pins: [f.pin] }));
  assert.throws(() => readLockedSnapshot(f.root, f.sdk), /locked SDK/);
});

test('invalid adoption input cannot produce a partial output snapshot', t => {
  const f = fixture(t);
  f.write('method-adoption.json', { schema: 'wrong', adopted: { stable: ['missing'] } });
  f.git('add', '.');
  f.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Invalid fixture authority');
  f.pin.state.revision = f.git('rev-parse', 'HEAD');
  writeFileSync(join(f.root, 'Package.resolved'), JSON.stringify({ pins: [f.pin] }));
  assert.throws(() => readLockedSnapshot(f.root, f.sdk), /adoption/);
});
