# LaunchToken ABI

`LaunchToken.json` is the full Solidity 0.8.26 ABI array for
`src/LaunchToken.sol:LaunchToken`, including the constructor, inherited ERC-20
functions, events, and custom errors. Regenerate it from the repository root:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
```

The nonpayable constructor has no inputs and mints `10^27` minor units to
`msg.sender`. In production that sender must be the launch factory.

| Function | Behavior |
| --- | --- |
| `name() -> string` | Returns `Daemon` |
| `symbol() -> string` | Returns `DAEMON` |
| `decimals() -> uint8` | Returns `18` |
| `totalSupply() -> uint256` | Returns `1000000000000000000000000000` |
| `balanceOf(address) -> uint256` | Balance in minor units |
| `allowance(address,address) -> uint256` | Current owner-to-spender allowance in minor units |
| `transfer(address,uint256) -> bool` | Moves the caller's tokens; returns true or reverts |
| `approve(address,uint256) -> bool` | Replaces the caller's allowance for a nonzero spender; returns true or reverts |
| `transferFrom(address,address,uint256) -> bool` | Moves tokens using the caller's allowance; returns true or reverts |

Amounts use integers: one DAEMON is `1000000000000000000` minor units. Reads are
`view`; all state-changing functions are nonpayable. Zero-value transfers are
supported for nonzero sender/receiver addresses. `transferFrom` requires an
allowance even when the caller is the token holder. Maximum uint256 allowances
are not decremented. There is no `permit` function.

`Transfer(address indexed from,address indexed to,uint256 value)` records all
transfers, including zero-value transfers and the constructor mint from the zero
address. `Approval(address indexed owner,address indexed spender,uint256 value)`
records explicit approvals. This version does **not** emit `Approval` when
`transferFrom` spends allowance; query `allowance()` for the current amount.
Some upstream comments in the vendored ERC-20 predate this behavior; its
`_spendAllowance` implementation is authoritative.

| Custom error | Meaning |
| --- | --- |
| `ERC20InsufficientBalance(address sender,uint256 balance,uint256 needed)` | Sender has fewer tokens than requested |
| `ERC20InvalidSender(address sender)` | Zero sender in the transfer routine |
| `ERC20InvalidReceiver(address receiver)` | Zero recipient |
| `ERC20InsufficientAllowance(address spender,uint256 allowance,uint256 needed)` | Caller cannot spend the requested amount |
| `ERC20InvalidApprover(address approver)` | Zero allowance owner |
| `ERC20InvalidSpender(address spender)` | Zero spender |

`transferFrom` checks allowance before transferring, so when multiple inputs are
invalid the allowance error may take priority. In particular, a zero-amount
`transferFrom` from the zero address reaches `ERC20InvalidApprover`. A reverted
call rolls back both the balances and allowance. Unknown function selectors and
ordinary ETH sends revert; there is no fallback or receive function.
