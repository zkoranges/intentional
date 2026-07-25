# Intentional public rename runbook

Status: provisional only. Do not execute until the active implementation plan
has merged to `main`, its worktree is clean, and CI is green.

## Decision

The public product is **Intentional**, served from **intentional.so**.

The rename is limited to public identity and presentation. Existing contract
identity remains unchanged because it is already deployed and is part of signed
protocol data.

### Public identity

| Surface | Required value |
|---|---|
| Product name | `Intentional` |
| Product domain and wordmark | `intentional.so` |
| GitHub repository | `zkoranges/intentional` |
| Vercel project | `intentional` |
| App and docs titles | `Intentional — Onchain factoring` |

### Compatibility identity that must not change

- Solidity contract names and source filenames.
- Deployed contract addresses and deployment manifests.
- EIP-712 domain name `"Reservoir v2"`.
- Quote envelope version `"reservoir-v2-lido-1"`.
- Existing storage namespaces and hashed keys.
- Existing environment-variable names used by deployed builds.
- Existing API enums and signed payload fields.

These values are implementation compatibility, not public branding. Changing
them would require a new deployment and a coordinated signer migration.

## Collision policy

The rename must be performed from a dedicated worktree after the active plan
finishes. One integrator owns the rename branch.

Do not combine the rename with feature changes. In particular, do not modify:

- `src/`
- protocol behavior in `frontend/lib/`
- `deployments/`
- fork, invariant, integration or unit-test behavior
- quote signer behavior

The rename branch may update tests only to enforce public naming.

Before starting:

1. Confirm every active agent has committed or explicitly parked its work.
2. Fetch and fast-forward `main`.
3. Record the baseline commit and CI URL.
4. Create `chore/intentional-public-rename` from that exact commit.
5. Confirm `git status --short` is empty in the rename worktree.

## Public surfaces to rename

### Frontend

- Header and footer wordmarks.
- Accessible labels.
- FAQ and user-facing status messages.
- Browser title and description.
- OpenGraph and Twitter metadata.
- Social-card image text.
- Favicon or manifest text, if any.
- `/docs` header, footer, metadata and product references.
- Local-storage keys, with a one-release fallback for the previous key.

Colors, typography, spacing, components, interactions and contract behavior
remain unchanged.

### Repository presentation

- Root `README.md` title, opening description and public URLs.
- Public architecture and submission documents where the project is presented
  by name.
- Badges, source links and GitHub Actions links.
- User-facing examples and screenshots.

Historical technical claims must stay accurate. A sentence may describe an old
deployment as a legacy implementation, but it must not present the current
product under the old name.

### Hosting and operations

- Rename the existing Vercel project to `intentional`.
- Keep `intentional.so` attached throughout the migration.
- Keep the old Vercel production alias until the custom domain passes smoke
  tests.
- Rename public service descriptions later; do not rename system users, unit
  names or filesystem paths during the presentation-only migration.

## Commit sequence

Keep the work reviewable and easy to revert:

1. `brand: centralize Intentional public metadata`
2. `brand: rename app and docs presentation`
3. `docs: present the repository as Intentional`
4. `test: reject legacy names on public surfaces`
5. `chore: update repository and hosting links`

Do not squash these commits. Their separation makes presentation changes
traceable without obscuring the feature history that came before them.

## GitHub repository rename

Rename the existing repository. Do not create a replacement repository and do
not rewrite Git history.

Preflight:

```sh
gh repo view zkoranges/intentional
git rev-list --all --count
git rev-parse HEAD
git rev-list --max-parents=0 HEAD
```

At the time this runbook was prepared, `zkoranges/intentional` did not resolve
to an existing repository. Check again immediately before the rename.

After the rename branch has merged:

```sh
gh repo rename intentional \
  --repo zkoranges/reservoir-v2-eth-lisbon \
  --yes

git remote set-url origin git@github.com:zkoranges/intentional.git
git fetch origin
```

Verification:

- The commit count is unchanged.
- The root commit SHA is unchanged.
- The rename merge commit is the only new commit.
- Branches, tags, releases, issues, pull requests and Actions history remain
  present.
- The previous GitHub URL redirects to the renamed repository.
- A fresh clone from the new URL checks out the same commit graph.

Renaming a GitHub repository preserves the commit graph and commit SHAs.
Rewriting history with `filter-repo`, `filter-branch`, rebasing published
history or force-pushing is forbidden.

## Domain and Vercel cutover

`intentional.so` has already been attached to the existing Vercel project.
Before cutover, verify its current state instead of assuming DNS has propagated:

```sh
vercel domains verify intentional.so --scope zkoranges-projects
vercel domains inspect intentional.so --scope zkoranges-projects
```

If DNS is still external and misconfigured, the previously recommended apex
records were:

```text
A  @  216.198.79.1
A  @  64.29.17.1
```

Re-run Vercel verification after the DNS provider reports the records live.

Cutover order:

1. Deploy the renamed frontend to the existing Vercel project.
2. Confirm the deployment through its immutable Vercel URL.
3. Confirm `https://intentional.so/` and `https://intentional.so/docs`.
4. Connect a wallet that owns unstETH and request a real firm offer.
5. Verify the exact NFT approval and atomic sale flow.
6. Connect and disconnect a wallet.
7. Verify metadata and the social-card image from the custom domain.
8. Rename the Vercel project in project settings.
9. Keep the previous Vercel alias for at least one release.

## Validation gates

### Naming

Rendered public pages must not contain:

- `Impatience`
- `impatience.xyz`
- public attribution naming the product `Reservoir`
- `reservoir-v2-eth-lisbon` except a temporary GitHub redirect test

Internal source identifiers and compatibility strings are explicitly allowed.
The naming test must inspect rendered/public output, not blindly reject internal
identifiers in source files.

### Product behavior

Run the existing frontend lint, unit tests and production build. Then verify:

- No synthetic payout is shown before the quote desk signs a seller- and
  request-bound firm offer.
- Firm quote validation still uses the unchanged EIP-712 domain.
- Wallet connect and disconnect still work.
- `/docs` renders.
- Desktop and mobile layouts retain the existing appearance.
- The opening-section illustration retains its existing placement.

### Protocol regression

Run the existing contract, signer and fork-test suites without updating golden
values merely to accommodate the rename. The point of this gate is to prove
that presentation changed while settlement did not.

## Rollback

The application rename is reverted by reverting the five rename commits in
reverse order.

The GitHub repository can be renamed back without changing commit SHAs. The Git
remote can then be restored to the previous URL.

The old Vercel deployment alias remains available during the cutover. If the
custom domain fails, route users to that alias while DNS is repaired.

No contract rollback is necessary because the presentation-only rename does not
modify or redeploy contracts.

## Definition of done

- `intentional.so` is the canonical public URL.
- The website, docs, metadata, README and repository use Intentional publicly.
- The GitHub repository is `zkoranges/intentional`.
- All pre-existing Git commit SHAs remain reachable.
- No contract address, signature domain, quote format or settlement behavior
  changed.
- The old names appear only in compatibility internals or historical Git
  snapshots, never as the current public product identity.
