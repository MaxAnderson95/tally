# Issue tracker: GitHub

Issues and specs live in MaxAnderson95/tally. Use `gh` with an explicit repository.

Use `--body-file` for issue and comment bodies. Read and edit issues through the REST API. Follow the `github-conventions` skill for provenance and body formatting.

PRs as a request surface: no.

## Wayfinding operations

- The map is an issue labelled `wayfinder:map`.
- Decision tickets are native sub-issues labelled `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Express blocking through native GitHub issue dependencies.
- The frontier is the map's open, unassigned children with no open blockers, in sub-issue order.
- Claim a ticket by assigning it to the developer driving the map before working on it.
- Resolve by posting a resolution comment, closing the ticket, and adding a linked gist to the map's Decisions so far.
- Use body-based parent/blocker links only if the corresponding native GitHub relationship is unavailable.
