# Documentation structure

The root README is the public setup and usage manual. Documentation/README.md
indexes the architecture and reference material. AGENTS.md routes agent work;
CONTRIBUTING.md describes contributor checks. Current package facts belong in
Documentation/Architecture/Package.md; commands, formats and operating detail
belong in Documentation/Reference/.

Execution state and local validation evidence belong in .agent/. Durable
transitions or accepted decisions may have separate history records when needed.
GitHub-specific configuration belongs in .github/.

The SwiftPM products are executables. Their user-facing interface is the CLI/MCP contract, documented in the manual and reference pages. There is no public library API or DocC catalog. Any future public library API needs a catalog beside its owning target; generated .doccarchive output remains a build artifact.
