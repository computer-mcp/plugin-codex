# Contributing

Changes belong to the artifact that owns their behavior. Describe the observable
change and include focused regression evidence. Preserve user configuration,
external dependencies and credentials.

## Validation

CI runs these checks on macOS; run them before opening a pull request. They need
Node.js, `jq` and `ripgrep`:

```sh
python3 Scripts/version.py check
swift package resolve && git diff --exit-code -- Package.resolved
Scripts/verify-swift-codex-release-gate.sh
node --test Tests/schema-import.test.mjs
node Scripts/import-schema.mjs --check
swift format lint --strict --recursive Package.swift Sources Tests
swift build --build-tests --disable-automatic-resolution
swift test --skip-build --disable-automatic-resolution --no-parallel
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 Scripts/package.py --output OUTPUT_DIRECTORY --configuration release
```

CI also packages and checks the Windows x86_64 archive on a Windows runner and
runs the organization brand check. Exercise help, valid input and invalid input
from outside the checkout. Keep command output contracts and generated resources
covered by tests.

## Documentation

The [documentation index](Documentation/README.md) links current architecture
and reference material. Agent work routes live in AGENTS.md; public usage lives
in the root README. GitHub collaboration files belong in .github/ and contributor
policy belongs in root governance files.

Contributions are licensed under this repository's [LICENSE](LICENSE),
FSL-1.1-ALv2.
