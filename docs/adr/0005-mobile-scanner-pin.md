# ADR-0005: `mobile_scanner` stays pinned at the vendored fork (7.2.0)

**Status:** Accepted (known gap, not resolved) · **Date:** 2026-08-09

## Context

`flutter/third_party/mobile_scanner` is a vendored fork of the
`mobile_scanner` package, pinned via `dependency_overrides` in
`pubspec.yaml` to version 7.2.0. It carries a local patch adding macOS
external-camera enumeration/selection, which upstream doesn't support.
Upstream has since moved to 7.4.0. During the 2026-08-09 dependency-bump
pass (all other non-`mobile_scanner` Flutter deps bumped via `flutter pub
upgrade --major-versions`, verified via `flutter test` + `flutter
analyze`), `mobile_scanner` was deliberately left untouched.

## Options (verified 2026-08-09)

- **Re-diff the macOS camera-enumeration patch onto 7.4.0 now** — gets the
  7.2→7.4 fixes (mostly camera lifecycle/orientation, not urgent) but is
  real effort with real risk of breaking camera selection, the core
  feature this fork exists for. Not attempted in this pass.
- **Stay pinned at 7.2.0, record the gap** — zero risk to the working
  camera-selection feature tonight; defers the upstream fixes. This is
  the decision.

## Decision

Keep `mobile_scanner` pinned at 7.2.0 via the local fork. Re-diffing onto
7.4.0 is real effort with real risk to camera selection (the fork's whole
reason to exist) for a changelog that's mostly camera
lifecycle/orientation fixes — not worth the risk tonight, recorded here
rather than silently left undocumented.

## Consequences

- Receiver doesn't get 7.2→7.4's upstream camera lifecycle/orientation
  fixes until this is revisited.
- Every future non-`mobile_scanner` dependency bump pass should re-check
  this gap rather than assume it's been addressed — `dependency_overrides`
  in `pubspec.yaml` silently prevents `flutter pub upgrade` from touching
  it, so it won't surface as a "needs attention" signal on its own.

## Open questions

- When to actually do the re-diff — no trigger condition set; revisit if
  a needed upstream fix (camera lifecycle/orientation bug) is hit in
  practice, rather than on a schedule.
