# Taxi (TAXI)

Taxi is a non-upgradeable ERC-20 with 18 decimals. Its constructor mints
100,000,000 TAXI (`100000000000000000000000000` base units) once to `msg.sender`.
There is no owner, later minting, public burning, pause, blacklist, seizure,
upgrade mechanism, fee setter, or exemption setter.

## Transfer rules

For both `transfer` and `transferFrom`, the requested amount is the **gross**
amount. On an ordinary transfer, `floor(amount / 100)` goes to the permanent
treasury `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7`; the recipient receives the
rest. For example, sending 100 TAXI delivers 99 TAXI and pays 1 TAXI to the
treasury. The fee is a transfer, not a burn. Total supply stays fixed.

Transfers **from or to** any of these endpoints are entirely exempt:

- The immutable factory address.
- The immutable pool manager address.
- The current address returned by `factory.distributorOf(launchNumber)`.

Exemptions depend on the balance owner and recipient, not the approved spender.
An exempt contract still needs allowance to spend somebody else's tokens.
Factory allocations, distributor claims, pool deposits, and pool withdrawals
therefore arrive whole. Swaps settling directly against the configured pool
manager are exempt; unrelated routers, pools, and intermediate wallet transfers
are subject to the ordinary rule.

Rounding and ERC-20 details:

- Amounts below 100 base units pay zero fee; splitting tiny transfers can avoid
  fractional fees. There is no minimum fee or accumulated fractional debt.
- Zero-value transfers to a nonzero address succeed and emit `Transfer`.
- Zero-address recipients and zero-address spenders are rejected.
- A taxable self-transfer costs only the fee, but requires the full gross balance.
- The treasury is not separately exempt. A transfer to it credits the entire
  gross amount; when it sends tokens, its fee portion returns to itself. Even
  then, the treasury must hold the full gross amount before sending.
- `transferFrom` consumes the gross allowance. OpenZeppelin's maximum-uint256
  allowance remains unchanged when spent. Failed transfers roll back allowances
  and balances. Replacing approvals has the usual ERC-20 ordering risk; wallets
  should revoke an existing approval before granting a new one when appropriate.
- A nonzero fee emits a treasury `Transfer` followed by the recipient `Transfer`.
  An exempt or rounded-to-zero fee emits just the recipient event. No token
  receiver hooks or ETH transfers are performed.

## Deployment parameters

Deploy the concrete artifact **`src/Taxi.sol:Taxi`** with three static arguments,
in this order:

| Argument | ABI type | Launch value |
| --- | --- | --- |
| `factory_` | `address` | `$factory` |
| `poolManager_` | `address` | `$poolManager` |
| `launchNumber_` | `uint64` | `$launchNumber` |

The first two must be nonzero. Launch number zero is supported; the real factory
determines which launch IDs are valid. These values are immutable. There is no
initialization call. The treasury, fee, name, symbol, decimals, and supply are
compiled constants or constructor-fixed values, not deployment arguments.

The factory should perform CREATE/CREATE2 directly so it receives the whole
supply. If a different contract or EOA deploys Taxi, **that actual deployer**
receives the supply instead; supplying a factory address does not redirect the
mint. Do not insert a deployment helper that would retain the launch supply.
The constructor makes no registry call, allowing deployment before registration.
The distributor is deliberately not a constructor argument: its address can
depend on the token address, and the factory registers it after token deployment.

The launch manifest's token fields should use name `Taxi`, symbol `TAXI`, decimals
`18`, totalSupply `"100000000000000000000000000"`, the artifact above, and the
ordered arguments above. No application contracts are required. This project
does not invent chain addresses, pool economics, or a launch manifest; those
values must come from the launch job. The 10% swarm allocation is performed by
the launch factory, not by a second token mint or constructor distribution.

## Registry assumptions and operations

The factory must expose `distributorOf(uint64)` and return exactly one canonical
ABI-encoded address within 30,000 gas. Taxi uses a bounded `STATICCALL` and copies
at most 32 bytes; the registry cannot modify state or reenter a state-changing
token operation during lookup. The distributor is read afresh, without caching.
The expected production factory keeps each launch's registered distributor
stable. If the external registry changes it, the new address becomes exempt and
the old address ceases to be exempt. This dependency is an external trust
assumption even though Taxi itself has no administrator.

A zero result, missing contract, revert, exhausted lookup gas, or malformed
response is treated as **no distributor exemption**. Ordinary transfers remain
usable and taxed; factory and pool manager transfers remain exempt. Claims will
be taxed until a valid distributor is available, so the launch operator must
verify registration and lookup success before enabling claims. Low-gas
transactions still need enough gas to complete the full transfer.

Before release, the operator is responsible for checking the target chain and
actual factory/pool manager addresses, factory registry semantics and gas needs,
treasury address, creation-code constructor arguments, deployed metadata and
supply, distributor registration, and pool settlement/claim integration. The
build targets Cancun-compatible EVMs. An independent adversarial review and
deployed-source verification remain release responsibilities. Treasury custody
and its spending policy belong to the treasury operator. Taxi has no privileged
recovery function; tokens accidentally sent to the token contract can be stuck.
Integrations outside the exempt paths must account for actual tokens received.

## Build and verification

With Foundry and Solidity **0.8.26** installed:

```sh
forge build
forge test
forge fmt --check
```

All dependency sources are ordinary vendored files. No dependency downloads,
environment variables, forks, RPC, wallet keys, FFI, or filesystem cheatcodes are
needed. `foundry.toml` pins the compiler, targets Cancun, enables optimization,
and uses `bytecode_hash = "none"` with CBOR metadata disabled. OpenZeppelin
Contracts v5.0.2 supplies the base ERC-20; provenance, original-file checksums,
and license are under `lib/openzeppelin-contracts/`. Tests use a small local
Foundry cheatcode interface rather than a network-installed test framework.

The tests cover deployment and mint events, fee rounding and transfer events,
all exemption directions through both transfer APIs, late distributor
registration, allowance behavior and rollback, invalid addresses, insufficient
funds, treasury/self-transfer aliases, prohibited administrative calls, runtime
opcode restrictions, and hostile registry responses. Four fuzz tests each run
1,000 cases by default; the sequence test checks a separate balance model and
supply conservation after 40 mixed transfers per case.

Local launch-flow tests model allocation, claims, and pool token movements with
test fixtures. They do not deploy a real Uniswap pool or replace the provided
protected launch integration harness, which needs the network's launch context
and factory-side sources. No transaction has been broadcast. Foundry tests and
a manual review against the provided security reference are the local checks;
Slither and Mythril are not part of this project's validation.
