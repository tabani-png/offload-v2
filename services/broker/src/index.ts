/**
 * @offload/broker
 * Credential broker: the only process with decrypt rights. Re-checks gate token and item hash before any commit and the declared read set before any read.
 *
 * Architecture only. No feature code yet. See docs/adr/0034-credential-broker-and-key-providers.md.
 * The first slice that touches this package replaces this marker.
 */
export type TodoBroker = "TODO: not implemented. See docs/adr/0034-credential-broker-and-key-providers.md";
