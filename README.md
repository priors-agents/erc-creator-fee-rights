# Creator Fee Rights (draft ERC)

One interface for the creator fee stream of a launched token: who receives it, what it has earned since launch, what
can be claimed now, and a claim anyone can call that always pays the recipient. Only the current recipient can name a
new one, and no administrator, launchpad setting or upgrade can change a launched token's recipient or lower its
creator share. A creator can point its stream at a contract that repays its lenders first, and cannot take it back
while it owes.

Every credit to a stream is logged in the transaction where the fee accrues, so a lender can recount `accruedTotal`
from logs instead of taking the launchpad's figure.

**Status: draft, submitted as [ethereum/ERCs#2103](https://github.com/ethereum/ERCs/pull/2103).** The text is in
[`ERCS/erc-draft_creator_fee_rights.md`](ERCS/erc-draft_creator_fee_rights.md). Its `eip: 99904` is a placeholder until
the ERC editors assign a number. Discussion: [Ethereum
Magicians](https://ethereum-magicians.org/t/erc-tba-creator-fee-rights/30027).

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
| `ERCS/erc-draft_creator_fee_rights.md` | The ERC text, in the ethereum/ERCs template |
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

- Agent Repay-First Payees: a revenue address that pays an agent's creditors before its owner
  (github.com/priors-agents/erc-repay-first-payees). A creator points its fee recipient at a payee so that its fees
  repay its lenders first; only the payee can then hand the stream back.
- Launch Declarations: what a launchpad declares at launch, its fee recipient included
  (github.com/priors-agents/erc-launch-declarations).

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
