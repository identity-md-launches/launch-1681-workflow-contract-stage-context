# Daemon contracts

Daemon (`DAEMON`) is a plain ERC-20 with 18 decimals and a fixed supply of
1,000,000,000 tokens. This contribution delivers the contract stage: source,
local tests, an exported ABI, and the handoff information below. The only launch
contract is `LaunchToken` in `src/LaunchToken.sol`; there are no application
contracts. Website implementation and the independently reviewed `launch.json`
belong to later assignments.

## Token behavior

The nonpayable constructor takes **no arguments**. It mints exactly
`1000000000000000000000000000` minor units to its immediate deployer, which is
the launch factory in production. It never calls another contract. No address,
key, oracle, or post-deployment initialization is needed.

Transfers move exactly the requested amount. There is no transfer tax, minting
after construction, public burning, owner, pause, blocklist, upgrade mechanism,
or special treatment of the creator or factory. The token does not distribute
launch allocations or collect trading fees. The standard OpenZeppelin ERC-20
implementation is vendored at version 5.0.2 without modifications.

Zero-value transfers to nonzero addresses succeed and emit `Transfer`. Transfers
to the zero address revert. Approvals replace the previous allowance; setting an
approval to zero revokes it. An allowance of `type(uint256).max` is unlimited and
does not decrease when spent. Changing an existing allowance has the standard
ERC-20 transaction-ordering risk; integrations should request only the allowance
needed and offer revocation. There is no permit extension.

ERC-20 transfers do not invoke a recipient callback. Sending DAEMON to this token
contract, or to another contract unable to release it, can lock those tokens
permanently. There is no rescue function. Ordinary ETH sends revert; forcibly
sent ETH cannot be recovered.

## Build and test

Run from the repository root with Foundry installed and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xcddd7b44177859615718f7b5bd9a99982514a78a6960fb33062f86d60ce7fe8a forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, the Cancun EVM, optimizer runs of 200, and
`bytecode_hash = "none"`. CBOR metadata is disabled. FFI is disabled and no
filesystem permissions are granted. All Solidity dependencies and their licenses
are ordinary files in `lib/`; no dependency download, submodule, RPC, account,
environment-based test configuration, or fork is required. The compiler and
Foundry executable are supplied by the verification runtime, not vendored here.
Dependency versions and upstream archive hashes are in
[`docs/dependency-provenance.json`](docs/dependency-provenance.json).

Tests cover metadata, constructor minting, CREATE2 factory deployment, exact
88/10/2 transfers, events, zero and self transfers, contract recipients, finite
and unlimited allowances, revocation, authorization boundaries, failed-call
rollback, invalid addresses, rejected ETH, missing administrative selectors, and
runtime size/opcodes. Five fuzz tests exercise successful and failing amounts;
two stateful invariants compare balances and allowances against a four-account
ledger across transfer/approve/transferFrom sequences. Tests use local actors
only; the deployment probe is not a production factory implementation.

Default testing uses 1,024 runs per fuzz test and 128 sequences of depth 64 per
invariant. These are test-coverage defaults, not economic parameters. The mint
amount is the private named constant `INITIAL_SUPPLY`, fixed by launch policy.
The final independent source/manifest review is still required; local testing
does not substitute for it. Slither and Mythril are not part of these checks.

Local validation with Forge 1.8.3 and Solidity 0.8.26 passed `forge build`, a
forced offline rebuild (`forge build --offline --force`), `forge fmt --check`,
and the seeded test command above. Forge reported 31 passing test groups:
30 unit/fuzz tests and one group containing both stateful invariants (8,192
handler calls, zero reverts). The exported ABI matches the compiled artifact.
Optimized runtime size is 1,709 bytes, below the 24,576-byte EIP-170 limit.

## ABI

[`docs/abi/LaunchToken.json`](docs/abi/LaunchToken.json) contains the compiler's
ABI array. [`docs/abi/README.md`](docs/abi/README.md) explains its functions,
events, error behavior, and export command. The only concrete production artifact
is `src/LaunchToken.sol:LaunchToken`. It has no linked-library placeholders.

## Launch parameters and responsibilities

These values are supplied by this assignment's canonical launch terms. They
describe the separate manifest/deployment handoff and are not constructor
arguments or token-enforced economics.

| Parameter | Value |
| --- | --- |
| Kind / chain | `evm_project` / Ethereum mainnet, chain ID `1` |
| Token artifact | `src/LaunchToken.sol:LaunchToken` |
| Name / symbol / decimals | `Daemon` / `DAEMON` / `18` |
| Constructor arguments | Empty |
| Application contracts | Empty list |
| Launch owner / creator | `0x23e5d7a7b4ea19530ec39c67cd46aa8c10d15acf` (`$owner`) |
| Pair currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Pool fee | `12500`, total 1.25%: 1% to the launch payer and 0.25% to IMD |
| Tick spacing | `60` |
| Manifest initial price | `"79228162514264337593543950336"` |
| Effective opening price | Derived by the deployer from an opening market cap of 2,500 IMD for the whole supply and actual currency ordering |

The supplied owner does not gain token administration; there is no owner argument
or owner storage. The factory initially holds all one billion tokens. It sends
880 million (88%) to the pool, 100 million (10%) to the launch's MerkleDistributor
for the swarm, and 20 million (2%) to the launch payer (or the policy treasury
when nobody pays). The workflow describes that payer as the creator. The swarm's
10% consists of 2% for accepted-work contributors and 8% for connected paired
seats, with distribution handled by services and the protocol. No supply is
reserved for any contract implemented here.

The separate manifest assignment writes `launch.json` with `LaunchToken` as the
launch token and an empty application-contract list. The protocol supplies the
pool guard and MerkleDistributor. Services publish source, link signed artifacts
and policy, attest, admit, deploy via the factory, and supply the deployment
handoff. There is no contributor broadcast script or transaction to sign here.
The services' deployment outputs are not prerequisites for building this token.

## Cosmetic mood and handoff conflict

The planned website computes Daemon's face off chain from the launch pool's
Swap events. It compares the current price to the UTC day's opening price: the
last post-swap price before midnight, or the first swap's pre-swap price when no
earlier swap exists. No swaps today means Smug. Otherwise the percentage change
maps to Crying at or below -20%, Grumpy above -20% through -5%, Smug above -5%
and below +5%, Content from +5% to below +20%, and Grinning from +20% upward.
This is cosmetic: price, mood, and time never change token balances, permissions,
or transfers. The spot price is not a financial oracle used by this contract.

**Review finding — pair/price mismatch:** the website brief assumes an ETH pair
with ETH as currency0, computes DAEMON's ETH price by inverting that pool price,
and uses ETH/USD for dollar values. The canonical launch terms instead fix an
IMD pair. An IMD/DAEMON pool alone cannot supply DAEMON's ETH price, and its
currency ordering is determined by the actual addresses. The frontend handoff
must resolve the denomination and any required conversion source before
publishing ETH/USD figures or routing ETH swaps. It must use the exact deployed
pool key, not assume ETH is currency0. No conversion feed, address, or price has
been guessed in this contribution. This finding does not affect ERC-20 behavior
and does not justify adding an onchain mood or pricing contract.

## After launch

There are no owner setters, initialization calls, or ongoing token maintenance.
Services are responsible for deployment and explorer verification. The frontend
contributor consumes the verified token address, chain, pool ID and exact pool
key from the deployment handoff, resolves the denomination finding, and connects
the cosmetic mood display and swap interface. The creator manages their own
wallet and uses the protocol's fee-claim process; those fees are not taken from
ERC-20 transfers. No live deployment, protocol factory integration test, source
publication, IPFS publication, or independent security review is claimed here.
