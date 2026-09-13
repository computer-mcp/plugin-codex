import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const check = args.includes('--check');
const positional = args.filter(x => x !== '--check');
if (positional.length !== 2 || !/^\d+\.\d+\.\d+$/.test(positional[1])) {
  throw new Error('Usage: node Scripts/import-schema.mjs EXPORT_ROOT CODEX_VERSION [--check]');
}
const [source, codexVersion] = positional;
const output = resolve(dirname(fileURLToPath(import.meta.url)), '../Sources/CodexAdapter/Resources/Protocol');
const receipt = { codexVersion, files: {} };
const artifacts = new Map();
for (const channel of ['stable', 'experimental']) {
  for (const kind of ['ClientRequest', 'ClientNotification', 'ServerRequest', 'ServerNotification']) {
    const name = `${channel}/${kind}.json`;
    const bytes = readFileSync(join(source, name));
    if (bytes.length > 2 * 1024 * 1024) throw new Error(`Schema too large: ${name}`);
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
    receipt.files[name] = { sha256: createHash('sha256').update(bytes).digest('hex'), messages: methods.length };
    artifacts.set(name, bytes);
  }
}
artifacts.set('receipt.json', Buffer.from(JSON.stringify(receipt, null, 2) + '\n'));
// Validate the entire input before replacing any derived artifact.
for (const [name, bytes] of artifacts) {
  const target = join(output, name);
  if (check) {
    if (!readFileSync(target).equals(bytes)) throw new Error(`Schema drift: ${name}`);
  } else {
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, bytes);
  }
}
process.stdout.write(JSON.stringify({ checked: check, ...receipt }, null, 2) + '\n');
