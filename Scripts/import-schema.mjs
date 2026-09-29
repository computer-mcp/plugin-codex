import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const channels = ['stable', 'experimental'];
const directions = ['ClientRequest', 'ClientNotification', 'ServerRequest', 'ServerNotification'];
const sdkSchemaRoot = 'Vendor/CodexAppServerProtocolSchema';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

// Read committed dependency inputs; a local SDK checkout may contain unrelated work.
export function readLockedSnapshot(packageRoot, sdkRepository) {
  const resolved = JSON.parse(readFileSync(join(packageRoot, 'Package.resolved')));
  const pins = resolved.pins.filter(pin => pin.identity === 'swift-codex');
  if (pins.length !== 1) throw new Error('Expected one locked swift-codex dependency');
  const { state, location } = pins[0];
  if (location !== 'https://github.com/swift-library/swift-codex.git' ||
      !/^[0-9a-f]{40}$/.test(state?.revision) || !/^\d+\.\d+\.\d+$/.test(state?.version)) {
    throw new Error('Invalid locked swift-codex dependency identity');
  }
  const read = (name, limit = 2 * 1024 * 1024) => {
    let bytes;
    try {
      bytes = execFileSync('git', ['-C', sdkRepository, 'show', `${state.revision}:${sdkSchemaRoot}/${name}`],
        { maxBuffer: limit + 1, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (cause) {
      throw new Error(`Cannot read locked SDK ${state.revision} input ${name}`, { cause });
    }
    if (bytes.length > limit) throw new Error(`SDK projection input exceeds its bound: ${name}`);
    return bytes;
  };
  const lock = JSON.parse(read('upstream.lock.json', 65536));
  const match = /^rust-v(\d+\.\d+\.\d+)$/.exec(lock.upstream?.tag);
  if (!match || !/^[0-9a-f]{40}$/.test(lock.upstream?.commit)) {
    throw new Error('SDK lock lacks its exact upstream identity');
  }
  const adoptionBytes = read('method-adoption.json', 65536);
  const adoption = JSON.parse(adoptionBytes);
  if (adoption.schema !== 'swift-codex.codex-app-server-method-adoption.v1' ||
      adoption.upstreamTag !== lock.upstream.tag || !Array.isArray(adoption.excluded)) {
    throw new Error('Invalid SDK method adoption metadata');
  }
  const receipt = {
    codexVersion: match[1],
    sdk: { version: state.version, revision: state.revision },
    upstream: { tag: lock.upstream.tag, commit: lock.upstream.commit },
    adoptionSHA256: digest(adoptionBytes),
    files: {},
  };
  const artifacts = new Map([['adoption.json', adoptionBytes]]);
  for (const channel of channels) {
    const adopted = adoption.adopted?.[channel];
    if (!Array.isArray(adopted) || adopted.some(method => typeof method !== 'string') ||
        new Set(adopted).size !== adopted.length) throw new Error(`Invalid ${channel} SDK adoption`);
    for (const kind of directions) {
      const name = `${channel}/${kind}.json`;
      const bytes = read(`${channel}/json/${kind}.json`);
      const document = JSON.parse(bytes);
      if (!Array.isArray(document.oneOf) || document.oneOf.length === 0) {
        throw new Error(`Missing message variants: ${name}`);
      }
      const methods = document.oneOf.map(variant => {
        const names = variant.properties?.method?.enum;
        if (!Array.isArray(names) || names.length !== 1 || typeof names[0] !== 'string') {
          throw new Error(`Ambiguous method: ${name}`);
        }
        return names[0];
      });
      if (new Set(methods).size !== methods.length) throw new Error(`Duplicate method: ${name}`);
      if (kind === 'ClientRequest' && adopted.some(method => !methods.includes(method))) {
        throw new Error(`SDK adoption references an absent ${channel} request`);
      }
      receipt.files[name] = { sha256: digest(bytes), messages: methods.length };
      artifacts.set(name, bytes);
    }
  }
  artifacts.set('receipt.json', Buffer.from(JSON.stringify(receipt, null, 2) + '\n'));
  return { receipt, artifacts };
}

export function syncArtifacts(snapshot, output, check) {
  for (const [name, bytes] of snapshot.artifacts) {
    const target = join(output, name);
    if (check) {
      if (!readFileSync(target).equals(bytes)) throw new Error(`SDK projection drift: ${name}`);
    } else {
      mkdirSync(dirname(target), { recursive: true });
      const temporary = `${target}.${process.pid}.tmp`;
      writeFileSync(temporary, bytes);
      renameSync(temporary, target);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  const check = args.includes('--check');
  const positional = args.filter(value => value !== '--check');
  if (positional.length > 1 || positional.some(value => value.startsWith('--'))) {
    throw new Error('Usage: node Scripts/import-schema.mjs [SDK_REPOSITORY] [--check]');
  }
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const sdk = resolve(positional[0] ?? join(root, '.build/checkouts/swift-codex'));
  const snapshot = readLockedSnapshot(root, sdk);
  syncArtifacts(snapshot, join(root, 'Sources/CodexAdapter/Resources/Protocol'), check);
  process.stdout.write(JSON.stringify({ checked: check, ...snapshot.receipt }, null, 2) + '\n');
}
