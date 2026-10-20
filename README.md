# ERC-8453: Creator Fee Rights (draft)

One interface for the creator fee stream of a launched token: who receives it, what it has earned since launch, what
can be claimed now, and a claim anyone can call that always pays the recipient. Only the current recipient can name a
new one, and no administrator, launchpad setting or upgrade can change a launched token's recipient or lower its
creator share. A creator can point its stream at a contract that repays its lenders first, and cannot take it back
while it owes.

Every credit to a stream is logged in the transaction where the fee accrues, so a lender can recount `accruedTotal`
from logs instead of taking the launchpad's figure.

**Status: draft, not submitted.** The text is in [`ERCS/erc-8453.md`](ERCS/erc-8453.md). ERC-8453 is the next number
that was free on 2026-10-20; the ERC editors confirm it, or assign another, when the pull request is opened on
ethereum/ERCs. Discussion opens on Ethereum Magicians first.

## Why

A creator fee stream is paid in the asset a token trades against, has an on-chain history, and repays a loan without a
sale into a pool, so it is the asset of a launch that a lender can lend against. Each launchpad models it differently:
Flaunch makes the stream a transferable NFT, Clanker and Doppler keep reward recipients or beneficiaries per token,
others take a recipient at launch and hold fees in an escrow. A lender has to integrate each one, and has no common
assurance that the creator, or the launchpad's operator, cannot redirect the fees once they are pledged. This interface
fixes the reads, the claim and the one rule that makes the pledge hold.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-8453.md` | The ERC text, in the ethereum/ERCs template |
| `src/ICreatorFeeRights.sol` | The interface |
| `src/CreatorFeeEscrow.sol` | A reference fee escrow a launchpad pays creator fees into (not audited) |
| `test/CreatorFeeEscrow.t.sol` | Foundry tests, including totals recounted from logs and a stream pledged to a payee |
| `test/mocks/Mocks.sol` | A launchpad, ERC-20 tokens and a repay-first payee reduced to what the tests need |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- ERC-8451 Agent Repay-First Payees: a revenue address that pays an agent's creditors before its owner
  (github.com/priors-agents/ERC-8451). A creator points its fee recipient at a payee so that its fees repay its lenders
  first; only the payee can then hand the stream back.
- ERC-8455 Launch Declarations: what a launchpad declares at launch, its fee recipient included
  (github.com/priors-agents/ERC-8455).

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
