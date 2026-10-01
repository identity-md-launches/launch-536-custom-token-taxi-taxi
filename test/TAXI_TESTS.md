# Additional Taxi checks

These tests extend the existing deployment, transfer, registry, and sequence tests.
They use the existing local cheatcode interface and require no new dependencies.

`TaxiAdversarial.t.sol` covers delegated self/treasury transfers, replay after
allowance exhaustion, revocation of infinite approvals, holder self-authorization,
zero transfers and invalid senders, rollback after insufficient gross balance,
exemptions changing between approval and spending, and launch IDs zero and maximum
uint64. Three properties each run 1,000 fuzz cases. The round-trip property checks
conservation and floor-rounding inequalities, with explicit zero, one, fee-boundary,
and full-supply examples.

`TaxiInvariant.t.sol` runs 256 random sequences of 64 calls. Foundry targets only
the seven actions in `helpers/TaxiHandler.sol`, so calls cannot bypass accounting.
The eight actors include the factory, pool manager, two potential distributors,
ordinary holders, and the fixed treasury. All possible recipients are tracked.

After each call the invariants check:

- Total supply and the sum of all balances remain 100,000,000 TAXI.
- Each balance matches an independent ledger initialized from the specified mint.
- Every actor-to-actor allowance matches approvals and successful gross spending;
  infinite allowances persist, replacements overwrite, and failed calls roll back.
- Constants, constructor parameters, and the selected launch's distributor match
  the expected configuration.

The handler mixes transfers, small/full-balance boundaries, independent approvals
and spending, prepared delegated transfers, registry changes, and six deliberate
failure modes. Expected failures must return the exact custom error. Unexpected
handler reverts fail the campaign through inline `fail-on-revert = true`.
Inputs are bounded without discarded cases. A deterministic replay also executes
every action and every failure mode.

`TaxiRegistryBoundary.t.sol` pins the registry lookup's 30,000-gas budget from the
outside: a registry that answers with the gas it received shows the stipend is at
most 30,000 and is not raised by a caller's gas; registries that demand just under
the budget are honored and ones that demand it or more are treated as absent, so a
claim through an over-budget registry arrives taxed rather than reverting (1,000 fuzz
cases over both ranges, plus pinned values at 29,000, 29,800, 30,000 and 30,001).
It also feeds the decoder a revert carrying a well-formed address, two-word and
33-byte answers, the value one above the address width, a zero word, and the widest
canonical address, and it lets the registry call back into the token during the
lookup: reads are honored, a write attempt is absorbed as "no distributor" and moves
nothing, and a registry that re-enters the lookup recursively is bounded by the
budget and never freezes a transfer.

`TaxiTransferProperties.t.sol` fuzzes a single transfer between any pair of the
seven endpoints (1,000 cases each). The Transfer events are the oracle for balances:
a fee event comes first and only when a fee is due, the recipient event carries the
remainder, replaying the events on a snapshot reproduces every balance, and no
third balance or unspent allowance moves. A gas-starved transfer is all-or-nothing:
with a cheap registry it never degrades an exempt claim into a taxed one, pinned at
25,000 gas (reverts whole) and 120,000 gas (applies the exemption whole).

Two token properties from the standard catalogues deliberately do not hold and are
asserted as the specification states them, not as the catalogue does: a taxable
self-transfer costs the fee, and the treasury is not exempt. Both are documented in
the README and were accepted in earlier rounds.

The registry is a fixture; changing it models external registry state, not a token
administrator. The local checks model token settlement endpoints. They do not run
the protected Uniswap integration harness, whose factory-side source dependencies
and launch environment are not present in this repository.

Run the complete local suite without network access or repository build artifacts:

```sh
forge build --offline --out /tmp/taxi-foundry-out --cache-path /tmp/taxi-foundry-cache
forge test --offline --out /tmp/taxi-foundry-out --cache-path /tmp/taxi-foundry-cache
```
