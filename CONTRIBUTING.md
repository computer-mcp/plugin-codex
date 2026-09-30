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

## Repository closeout

Use the default branch for daily integration and a task branch or isolated
worktree for changes. Before cleanup, inspect local changes, worktree owners,
open pull requests and the accepted source revision. Preserve unrelated source,
credentials, runtime state and non-generated ignored files; never reset, clean
or stash another task's work to make a checkout appear clean.

After delivery, fast-forward only a clean integration checkout. Retire a task
branch only when its tip is in the accepted default branch or its exact head
matches a merged pull request whose merge is reachable there. Preserve unique
work with a documented reconciliation and independently verified recovery
bundle before retiring its directory. Remove owned worktrees through Git, or
through the managing application's archive operation for managed worktrees.

Build caches in the daily checkout may remain useful. Remove inactive duplicate
task caches, package staging and disposable test outputs after checking their
owner and running references. Preserve source inputs, immutable release
artifacts, necessary failure/acceptance evidence and required rollback state.
Keep local progress and recovery inventories under ignored `.agent/`; current
product behavior must remain understandable from committed documentation.

A merged source change, a validated package and a published release have
different identities. Record the exact source and artifact/check evidence at
handoff. Documentation or repository cleanup alone does not require a product
release; published tags and assets remain immutable. Active dependency-update
pull requests are reviewed maintenance work, not disposable cleanup residue.
