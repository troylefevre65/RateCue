# Security policy

RateCue is a development preview. Security fixes are made on `main`; there are no maintained release branches.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/troylefevre65/RateCue/security/advisories/new). Do not open a public issue for a suspected vulnerability.

Include the affected revision, macOS version, the minimal steps to reproduce, and the impact you observed. Redact track identifiers, personal file paths, device UIDs, and credentials.

## Scope

In scope:

- The menu bar app, the bundled `ratecue` CLI, and the local app exchange used by the CLI and MCP helper.
- The experimental MCP helper, including any way to reach control tools without `RATECUE_MCP_ALLOW_CONTROL=1` or to bypass the output allowlist.
- Diagnostics or traces that leak track titles, paths, device identifiers, or other private data despite their documented redaction.
- Any path by which an estimate triggers a device write.

Out of scope:

- The local app exchange does not authenticate other processes running as the same user; see [MCP-SPECIFICATION.md](MCP-SPECIFICATION.md).
- Behavior of third-party model servers configured with `Scripts/local-agent.py`.
- Development builds are not notarized and have no updater.
