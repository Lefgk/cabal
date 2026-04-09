// Connected flow. Injects a fake EIP-1193 provider before the app loads,
// then clicks every write button and asserts that the expected transaction
// was captured by the mock. The mock forwards read-only JSON-RPC to live
// PulseChain, so the page reflects real on-chain state (balances, top
// stakers, proposals, etc.).

import { test, expect } from '@playwright/test';
import { MOCK_PROVIDER_SOURCE } from './fixtures/mockProvider.js';

// Known top-100 staker on PulseChain — using it as the mock account means
// `isTopStaker(msg.sender)` returns true so the Create Proposal form is
// interactable. (We never actually sign anything against this address; the
// mock captures sendTransaction and returns a fake hash.)
const TOP_STAKER = '0xa0419404eF7b81d9Ec64367eb68e5f425EACE618';

const ADDRESSES = {
  stakingVault: '0x57124b4E6b44401D96D3b39b094923c5832dC769',
  treasuryDAO: '0xE27E3963cDF3B881a467f259318ca793076B42A1',
  stakeToken: '0x1745A8154C134840e4D4F6A84dD109902d52A33b',
};

// ERC-20 / custom function selectors we check against captured `data`.
const SELECTORS = {
  approve: '0x095ea7b3',
  transfer: '0xa9059cbb',
  stake: '0xa694fc3a',
  withdraw: '0x2e1a7d4d',
  getReward: '0x3d18b912',
  exit: '0xe9fad8ee',
  propose: '0x476b13e4',
  castVote: '0x15373e3d',
  executeProposal: '0x0d61b519',
};

async function injectWallet(page, account = TOP_STAKER) {
  await page.addInitScript((addr) => {
    window.__MOCK_ACCOUNT__ = addr;
  }, account);
  await page.addInitScript({ content: MOCK_PROVIDER_SOURCE });
}

async function connect(page) {
  const connectBtn = page.getByRole('button', { name: /Connect Wallet/i });
  if (await connectBtn.isVisible().catch(() => false)) {
    await connectBtn.click();
  }
  // Header button flips to truncated address once connected.
  await expect(
    page.getByRole('button', { name: new RegExp(TOP_STAKER.slice(2, 6), 'i') }),
  ).toBeVisible({ timeout: 20_000 });
}

async function lastTx(page) {
  return await page.evaluate(() => {
    const arr = window.__SENT_TXS__ || [];
    return arr[arr.length - 1] || null;
  });
}

async function txCount(page) {
  return await page.evaluate(() => (window.__SENT_TXS__ || []).length);
}

test.describe('cabal dao — connected wallet flow', () => {
  test.beforeEach(async ({ page }) => {
    await injectWallet(page);
    await page.goto('/');
    await connect(page);
  });

  test('header shows truncated connected address, disconnect works', async ({ page }) => {
    const addrBtn = page.getByRole('button', {
      name: new RegExp(`${TOP_STAKER.slice(0, 6)}.+${TOP_STAKER.slice(-4)}`, 'i'),
    });
    await expect(addrBtn).toBeVisible();

    await addrBtn.click();
    await expect(page.getByRole('button', { name: /Connect Wallet/i })).toBeVisible();
  });

  test('staking: Approve sends an ERC-20 approve to the vault', async ({ page }) => {
    const before = await txCount(page);
    await page.getByPlaceholder('Amount to stake').fill('1');

    const approveBtn = page.getByRole('button', { name: /^Approve$/ });
    // Whether we see Approve or Stake depends on the current on-chain
    // allowance for TOP_STAKER. If allowance is already high, the Stake
    // button will be shown instead — handle both.
    if (await approveBtn.isVisible().catch(() => false)) {
      await approveBtn.click();
      await expect.poll(() => txCount(page)).toBeGreaterThan(before);
      const tx = await lastTx(page);
      expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakeToken.toLowerCase());
      expect(tx.data.startsWith(SELECTORS.approve)).toBeTruthy();
    } else {
      test.info().annotations.push({
        type: 'skip-reason',
        description: 'allowance already set on-chain — Approve button not shown',
      });
    }
  });

  test('staking: Stake sends stake(uint256) to the vault', async ({ page }) => {
    await page.getByPlaceholder('Amount to stake').fill('1');

    const stakeBtn = page.getByRole('button', { name: /^Stake$/ });
    if (!(await stakeBtn.isVisible().catch(() => false))) {
      test.info().annotations.push({
        type: 'skip-reason',
        description: 'needs approval first — Stake button not shown',
      });
      return;
    }
    const before = await txCount(page);
    await stakeBtn.click();
    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakingVault.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.stake)).toBeTruthy();
  });

  test('staking: Withdraw sends withdraw(uint256) to the vault', async ({ page }) => {
    const before = await txCount(page);
    await page.getByPlaceholder('Amount to withdraw').fill('1');
    await page.getByRole('button', { name: 'Withdraw', exact: true }).click();

    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakingVault.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.withdraw)).toBeTruthy();
  });

  test('staking: Claim Rewards sends getReward()', async ({ page }) => {
    const before = await txCount(page);
    await page.getByRole('button', { name: /Claim Rewards/i }).click();
    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakingVault.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.getReward)).toBeTruthy();
  });

  test('staking: Exit sends exit()', async ({ page }) => {
    const before = await txCount(page);
    await page.getByRole('button', { name: /Exit \(Withdraw All/i }).click();
    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakingVault.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.exit)).toBeTruthy();
  });

  test('staking: Top Stakers toggle shows + hides the list', async ({ page }) => {
    const toggle = page.getByRole('button', { name: /Top Stakers/i });
    if (!(await toggle.isVisible().catch(() => false))) {
      test.info().annotations.push({
        type: 'skip-reason',
        description: 'no top stakers on-chain yet',
      });
      return;
    }
    await toggle.click();
    await expect(page.locator('.top-staker-item').first()).toBeVisible();
    await toggle.click();
    await expect(page.locator('.top-staker-item').first()).toBeHidden();
  });

  test('token info: Transfer rejects invalid address', async ({ page }) => {
    await page.getByPlaceholder(/Recipient address/i).fill('not-an-address');
    await page.getByPlaceholder(/Amount of /i).fill('1');
    await expect(page.getByText(/Invalid address/i)).toBeVisible();
    await expect(page.getByRole('button', { name: /^Transfer$/ })).toBeDisabled();
  });

  test('token info: Transfer sends ERC-20 transfer with valid inputs', async ({ page }) => {
    const before = await txCount(page);
    await page.getByPlaceholder(/Recipient address/i).fill(TOP_STAKER);
    await page.getByPlaceholder(/Amount of /i).fill('0.5');

    const btn = page.getByRole('button', { name: /^Transfer$/ });
    await expect(btn).toBeEnabled();
    await btn.click();

    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.stakeToken.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.transfer)).toBeTruthy();
    // Recipient address is the last 20 bytes of the first 32-byte arg
    // following the selector (padded left with zeros).
    expect(tx.data.toLowerCase()).toContain(TOP_STAKER.slice(2).toLowerCase());
  });

  test('proposals: Submit sends propose() from a top staker', async ({ page }) => {
    // The TOP_STAKER account is actually in the top-100 list on chain, so
    // the Submit button should be interactable. Still, gate on visibility
    // in case that changes.
    const amount = page.locator('input').filter({ hasText: '' }).nth(0); // fallback selectors below
    // Prefer stable form-label selectors:
    await page.locator('label', { hasText: /^Amount \(WPLS\)/ }).locator('..').locator('input').fill('0.01');
    await page.locator('label', { hasText: /^Target address/ }).locator('..').locator('input').fill(TOP_STAKER);
    await page.locator('label', { hasText: /^Description/ }).locator('..').locator('textarea').fill('e2e test proposal');

    const submit = page.getByRole('button', { name: /^Submit$/ });
    await expect(submit).toBeEnabled();
    const before = await txCount(page);
    await submit.click();

    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.treasuryDAO.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.propose)).toBeTruthy();
  });

  test('proposals: Vote Yes / No on any active proposal (if present)', async ({ page }) => {
    const yes = page.getByRole('button', { name: /Vote Yes/i }).first();
    if (!(await yes.isVisible().catch(() => false))) {
      test.info().annotations.push({
        type: 'skip-reason',
        description: 'no active proposals on-chain to vote on',
      });
      return;
    }
    const before = await txCount(page);
    await yes.click();
    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.treasuryDAO.toLowerCase());
    expect(tx.data.startsWith(SELECTORS.castVote)).toBeTruthy();
  });

  test('proposals: Execute button sends executeProposal for succeeded props', async ({ page }) => {
    const exec = page.getByRole('button', { name: /Execute Proposal/i }).first();
    if (!(await exec.isVisible().catch(() => false))) {
      test.info().annotations.push({
        type: 'skip-reason',
        description: 'no succeeded proposals on-chain to execute',
      });
      return;
    }
    const before = await txCount(page);
    await exec.click();
    await expect.poll(() => txCount(page)).toBeGreaterThan(before);
    const tx = await lastTx(page);
    expect(tx.to.toLowerCase()).toBe(ADDRESSES.treasuryDAO.toLowerCase());
  });
});
