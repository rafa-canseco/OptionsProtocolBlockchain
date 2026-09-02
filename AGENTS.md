# Contracts Agent Protocol

This file is the canonical protocol for every coding agent working in
`blockchain/`. Tool-specific instruction files must point here instead of
duplicating these rules.

## Scope and boundaries

- Write only inside `blockchain/`; read sibling repositories only when a task
  needs an integration contract.
- Never access `../options-scenarios/`. It is a holdout boundary; work only from
  failure messages supplied by the user.
- Treat all contract and fund work as authorized defensive engineering. Report
  review results as root cause, affected invariant, impact, fix, and regression
  evidence.
- Do not expose, print, commit, or push credentials. `.env*`, `.secrets/`, keys,
  and broadcast artifacts stay local. `.env.example` may contain names and safe
  placeholders only.

## Active product context

- V2 is the active initiative and is Base-only. Before V2 work, read
  `../docs/v2/V2_OPERATING_CONTEXT.md` plus the assigned Linear issue.
- Milestone 1 is the ETH/USDC CSP Vault and fund path, with modularity for later
  assets and covered-call/meta-vault milestones.
- Existing V1 contracts, deployments, tests, and runbooks are compatibility
  evidence, not the default design source. Change or extend legacy behavior only
  when the ticket explicitly requires it.
- Linear (workspace `b1nary`, team `B1N`) is the task source of truth. Do not
  create a second backlog in the repository.

## Start protocol

1. Confirm the issue, acceptance criteria, affected invariants, and target
   integration branch.
2. Read only the architecture and code paths needed for that task; avoid loading
   the whole historical playbook into context.
3. Run `npm ci --ignore-scripts` when dependencies are absent or the lockfile
   changed.
4. Run `npm run harness:doctor`, use the narrowest relevant Forge selector while
   editing, and run `npm run harness:fast` once before handoff.
5. For implementation work, record the plan on the Linear issue and wait for
   approval when the issue workflow requires approval.

## Implementation rules

- Solidity compiler and dependency versions are pinned. Do not broaden version
  ranges without an explicit dependency ticket.
- Preserve storage layout and initialization safety for upgradeable contracts.
- Make custody, authorization, accounting, settlement, and upgrade invariants
  explicit in tests.
- Keep fork/network behavior out of ordinary unit checks. Add fork evidence only
  to a clearly named `*Fork.t.sol` suite with a documented chain and pinned block
  when the assertion depends on historical state.
- Use Blockscout for verification; do not introduce Basescan/Etherscan workflows.
- Do not modify product behavior merely to make a harness check pass. Report an
  existing failure as baseline evidence unless the ticket authorizes its fix.

## Verification and evidence

- `npm run harness:fast` is the deterministic handoff gate. It is offline,
  excludes fork suites, and routes fuzz/invariant property functions to
  `extended`; ordinary deterministic functions remain in `fast`.
- During the edit/test loop, use the smallest relevant `forge test` selector. A
  clean checkout or Solidity change can trigger a slow `via-ir` compilation;
  subsequent gates reuse Foundry's cache.
- `npm run harness:extended` runs only security-profile fuzz/invariant properties
  and explicit Base mainnet/Base Sepolia forks. It fails closed unless required
  RPC configuration is present.
- `npm run harness:full` remains the comprehensive local gate and runs fast plus
  extended verification.
- Changes affecting custody, settlement, authorization, upgrades, or deployment
  require deep evidence from `docs/HARNESS_VERIFICATION.md` and an independent
  defensive review. A task is not done based only on an implementer's summary.
- Never mark work complete while required checks are failing or skipped. State
  the exact pre-existing or newly introduced blocker.

## Git and delivery

- V2 branches start from and target `staging`; never use historical `dev` for V2.
- Use a dedicated feature branch/worktree per ticket. Include the issue ID in
  branch and PR titles.
- After required verification and independent review pass, create a local
  ticket-scoped commit by default. Never commit a failing handoff.
- Push the verified feature branch, open a draft PR to `staging`, attach evidence
  plus `Fixes B1N-<id>`, and move Linear to Review by default. Do not merge,
  deploy, or verify a deployment unless the user requests it.
- Before handoff, provide changed-file scope, acceptance-criteria mapping,
  verification evidence, unresolved failures, and integration dependencies.

## Deployment verification

Use Blockscout when an explicitly authorized deployment ticket requires source
verification. Existing deploy/verify scripts remain task-specific and must not
run as a side effect of the quality harness.
