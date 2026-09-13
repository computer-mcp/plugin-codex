# Contributing

Changes belong to the artifact that owns their behavior. Describe the observable
change and include focused regression evidence. Preserve user configuration,
external dependencies and credentials.

## Validation

Run `swift build`, `swift test`, and strict `swift-format` lint. Exercise help, valid input and invalid input from outside the checkout. Keep command output contracts and generated resources covered by tests.

## Documentation

The [documentation index](Documentation/README.md) links current architecture
and reference material. Agent work routes live in AGENTS.md; public usage lives
in the root README. GitHub collaboration files belong in .github/ and contributor
policy belongs in root governance files. Execution notes belong in .agent/.
