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

The registry is a fixture; changing it models external registry state, not a token
administrator. The local checks model token settlement endpoints. They do not run
the protected Uniswap integration harness, whose factory-side source dependencies
and launch environment are not present in this repository.

Run the complete local suite without network access or repository build artifacts:

```sh
forge build --offline --out /tmp/taxi-foundry-out --cache-path /tmp/taxi-foundry-cache
forge test --offline --out /tmp/taxi-foundry-out --cache-path /tmp/taxi-foundry-cache
```
