# Architecture Decision Records

Non-obvious, reversible-but-significant decisions. Add a new numbered file
when you change the wire format, the fountain PRNG/degree table, the
isolate/threading model, disk persistence semantics, or a language/runtime
choice.

| #                                        | Decision                                                   | Status                            |
| ---------------------------------------- | ---------------------------------------------------------- | --------------------------------- |
| [0001](./0001-worker-isolate.md)         | Flutter receiver worker isolate                            | Accepted                          |
| [0002](./0002-fountain-vs-sequential.md) | Fountain (LT-code) vs. sequential chunk encoding           | Accepted                          |
| [0003](./0003-disk-hydration.md)         | Disk hydration design                                      | Accepted                          |
| [0004](./0004-sender-language-rust.md)   | Sender language — TypeScript → Rust                        | Accepted (QR-display sender only) |
| [0005](./0005-mobile-scanner-pin.md)     | `mobile_scanner` stays pinned at the vendored fork (7.2.0) | Accepted (known gap)              |
| [0006](./0006-port-join-to-rust.md)      | `porter join` ported to Rust; `nodejs/` and all JS deleted  | Accepted (resolves 0004's defer)  |

See also: [`../../flutter/docs/architecture.md`](../../flutter/docs/architecture.md) (receiver architecture) · [`../superpowers/specs/`](../superpowers/specs/) (implementation specs).
