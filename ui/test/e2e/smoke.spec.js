// Disconnected smoke test. No wallet is injected, so the app should render
// in its read-only state: all sections visible, all write buttons disabled,
// gating messages for proposal creation / transfer / staking visible.

import { test, expect } from '@playwright/test';

test.describe('cabal dao — disconnected smoke', () => {
  test.beforeEach(async ({ context }) => {
    // Make absolutely sure no wallet leaks in from previous tests.
    await context.addInitScript(() => {
      try { delete window.ethereum; } catch (_) { /* noop */ }
    });
  });

  test('renders all four section cards + header', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('heading', { name: 'Cabal DAO', level: 1 })).toBeVisible();

    await expect(page.getByRole('heading', { name: 'Staking', level: 2 })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Treasury & DAO', level: 2 })).toBeVisible();
    await expect(page.getByRole('heading', { name: /\(TSTT\)|Token/, level: 2 })).toBeVisible();
    await expect(page.getByRole('heading', { name: /^Proposals/, level: 2 })).toBeVisible();
  });

  test('shows Connect Wallet button when disconnected', async ({ page }) => {
    await page.goto('/');
    const connect = page.getByRole('button', { name: /Connect Wallet/i });
    await expect(connect).toBeVisible();
    await expect(connect).toBeEnabled();
  });

  test('staking inputs + action buttons are present and disabled', async ({ page }) => {
    await page.goto('/');

    const stakeInput = page.getByPlaceholder('Amount to stake');
    const withdrawInput = page.getByPlaceholder('Amount to withdraw');
    await expect(stakeInput).toBeVisible();
    await expect(stakeInput).toBeDisabled();
    await expect(withdrawInput).toBeVisible();
    await expect(withdrawInput).toBeDisabled();

    // The stake input shows either "Approve" or "Stake" — both should exist
    // in the DOM, but be disabled because no wallet is connected.
    const stakeBtns = page.getByRole('button', { name: /^(Approve|Stake)$/ });
    await expect(stakeBtns.first()).toBeDisabled();

    await expect(page.getByRole('button', { name: 'Withdraw', exact: true })).toBeDisabled();
    await expect(page.getByRole('button', { name: /Claim Rewards/i })).toBeDisabled();
    await expect(page.getByRole('button', { name: /^Exit \(Withdraw All/i })).toBeDisabled();

    await expect(page.getByText(/Connect wallet to stake/i)).toBeVisible();
  });

  test('transfer form is present and disabled with help text', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: 'Transfer', level: 3 })).toBeVisible();

    const toInput = page.getByPlaceholder(/Recipient address/i);
    await expect(toInput).toBeVisible();
    await expect(toInput).toBeDisabled();

    const amountInput = page.getByPlaceholder(/Amount of /i);
    await expect(amountInput).toBeVisible();
    await expect(amountInput).toBeDisabled();

    await expect(page.getByRole('button', { name: /^Transfer$/ })).toBeDisabled();
    await expect(page.getByText(/Connect wallet to transfer/i)).toBeVisible();
  });

  test('create-proposal form is gated on wallet connect', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: 'Create Proposal', level: 3 })).toBeVisible();
    await expect(page.getByText(/Connect wallet to propose/i)).toBeVisible();

    // All inputs disabled, Submit disabled.
    const submit = page.getByRole('button', { name: /^Submit$/ });
    await expect(submit).toBeDisabled();
  });

  test('treasury section renders live on-chain stats', async ({ page }) => {
    await page.goto('/');

    // "Available" label present; the value should resolve from "..." to a
    // number within a reasonable window (live RPC).
    const available = page
      .locator('.stat-box')
      .filter({ hasText: /^Available/ })
      .locator('.stat-value');
    await expect(available).toBeVisible();
    await expect(available).not.toHaveText('...', { timeout: 30_000 });
  });

  test('token info lifetime totals and tax structure render', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: /Tax Structure/i })).toBeVisible();
    await expect(page.getByRole('heading', { name: /Lifetime Totals/i })).toBeVisible();
    await expect(page.getByRole('heading', { name: /^Owners$/i })).toBeVisible();
  });

  test('otterscan address links point at otter.pulsechain.com', async ({ page }) => {
    await page.goto('/');
    const firstLink = page.locator('a.address-link').first();
    await expect(firstLink).toBeVisible();
    const href = await firstLink.getAttribute('href');
    expect(href).toMatch(/^https:\/\/otter\.pulsechain\.com\/address\/0x[a-fA-F0-9]{40}$/);
  });
});
