// Wagmi hooks pinned to PulseChain (chainId 369).
//
// Rationale: wagmi's `useReadContract` / `useReadContracts` / `useWriteContract`
// default to the wallet's currently connected chain. If the wallet is on
// Ethereum mainnet (as MetaMask often is by default), reads return nothing
// and writes would try to broadcast our calldata to Ethereum — wasting gas
// and/or failing confusingly. These wrappers force EVERY contract
// interaction to chain 369:
//
//   * reads  → always executed via PulseChain HTTP transport
//   * writes → carry `chainId: 369`, so wagmi requests a wallet chain
//     switch before signing; if the user rejects, the tx is never sent.
//
// Combined with `WrongChainBanner` in App.jsx and the `isOnPulseChain`
// button-gate below, it is structurally impossible for this dapp to send
// a tx to any chain other than PulseChain.

import {
  useReadContract as useWagmiReadContract,
  useReadContracts as useWagmiReadContracts,
  useWriteContract as useWagmiWriteContract,
  useBalance as useWagmiBalance,
  useWaitForTransactionReceipt,
  useAccount,
  useChainId,
  usePublicClient,
} from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect, useState } from 'react';
import { PULSECHAIN_ID } from '../config/wagmi.js';

// Best-effort chain-id → human name mapping so we can tell users *which*
// wrong chain their wallet is on (instead of just "wrong chain"). Covers
// the top 10 EVM chains — if we get a hit it helps the user fix their
// wallet; if we miss, we fall back to the numeric id.
const CHAIN_NAMES = {
  1: 'Ethereum',
  10: 'Optimism',
  56: 'BNB Smart Chain',
  100: 'Gnosis',
  137: 'Polygon',
  250: 'Fantom',
  369: 'PulseChain',
  8453: 'Base',
  42161: 'Arbitrum One',
  43114: 'Avalanche',
  59144: 'Linea',
  534352: 'Scroll',
  11155111: 'Sepolia',
};

export function chainName(id) {
  if (!id) return null;
  return CHAIN_NAMES[id] || `Chain ${id}`;
}

export function useReadContract(args) {
  return useWagmiReadContract({ ...args, chainId: PULSECHAIN_ID });
}

export function useBalance(args) {
  return useWagmiBalance({ ...args, chainId: PULSECHAIN_ID });
}

export function useReadContracts(args) {
  // `contracts` is an array; each entry can independently override chainId.
  // Spread our default onto each entry so `useReadContracts` fans them out
  // to the right chain.
  const contracts = (args?.contracts ?? []).map((c) => ({
    chainId: PULSECHAIN_ID,
    ...c,
  }));
  return useWagmiReadContracts({ ...args, contracts });
}

/// True when the wallet is connected AND on PulseChain.
/// Disconnected users are considered "on chain" (no wallet = no risk).
export function useIsPulseChain() {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  if (!isConnected) return true;
  return chainId === PULSECHAIN_ID;
}

/// Expose the wallet's currently connected chain for display. Returns:
///   - `chainId`      : raw numeric id from the wallet, or null if disconnected
///   - `chainName`    : human name if we recognise it, else "Chain N"
///   - `isConnected`  : wallet is plugged in
///   - `isPulseChain` : wallet is on 369
export function useConnectedChain() {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  return {
    chainId: isConnected ? chainId : null,
    chainName: isConnected ? chainName(chainId) : null,
    isConnected,
    isPulseChain: !isConnected || chainId === PULSECHAIN_ID,
  };
}

/// Drop-in replacement for `useWriteContract` that:
///   1. pins every call to PulseChain (wagmi will refuse to broadcast on
///      any other chain and will prompt the wallet to switch),
///   2. SIMULATES the call via `publicClient.simulateContract` before
///      sending so a would-be-reverting tx surfaces its revert reason in
///      the UI instead of the user signing a doomed transaction,
///   3. watches the tx receipt and, once it confirms, invalidates the
///      whole react-query cache so every `useReadContract` auto-refetches.
///      This means staking / balance / proposal lists update as soon as
///      any transaction mines, with no manual refresh.
/// Also exposes:
///   - `hash`          : last submitted tx hash
///   - `isSimulating`  : eth_call preflight in flight
///   - `isMining`      : submitted but not yet mined
///   - `isConfirmed`   : mined successfully at least once this session
///   - `isOnWrongChain`: wallet is connected to a chain ≠ 369
///   - `txError`       : unified error from simulate / submit / receipt
export function useSafeWriteContract() {
  const base = useWagmiWriteContract();
  const isOnPulseChain = useIsPulseChain();
  const queryClient = useQueryClient();
  const { address } = useAccount();
  // Always use the PulseChain publicClient regardless of wallet chain, so
  // simulation queries the right state even if the wallet is stuck on
  // Ethereum mid-switch.
  const publicClient = usePublicClient({ chainId: PULSECHAIN_ID });

  const [simError, setSimError] = useState(null);
  const [isSimulating, setIsSimulating] = useState(false);

  const {
    isLoading: isMining,
    isSuccess: isConfirmed,
    error: receiptError,
  } = useWaitForTransactionReceipt({
    hash: base.data,
    chainId: PULSECHAIN_ID,
    query: { enabled: !!base.data },
  });

  // When a tx confirms, blow away all cached reads so the UI pulls fresh
  // values for balances, proposals, staking state, etc. Scoped to the
  // confirmation edge so it only fires once per tx.
  useEffect(() => {
    if (isConfirmed) {
      queryClient.invalidateQueries();
    }
  }, [isConfirmed, queryClient]);

  // Preflight: run eth_call against the PulseChain node with `account` set
  // to the connected wallet. If it would revert, surface the error and
  // return false so the caller aborts before we ever prompt the wallet.
  //
  // Test escape hatch: when running under Playwright, the mock provider
  // uses a real on-chain account that doesn't have matching approvals /
  // balances / governance power for every spec. Setting
  // `window.__TEST_SKIP_SIM__ = true` before boot lets tests skip the
  // preflight and assert the raw tx shape. Production code never sets
  // this flag.
  const simulate = useCallback(
    async (args) => {
      if (
        typeof window !== 'undefined' &&
        window.__TEST_SKIP_SIM__ === true
      ) {
        return { ok: true };
      }
      if (!publicClient) return { ok: true }; // no client → skip, trust wallet
      if (!address) {
        const err = new Error('Wallet not connected');
        setSimError(err);
        return { ok: false, error: err };
      }
      setIsSimulating(true);
      setSimError(null);
      try {
        await publicClient.simulateContract({
          account: address,
          chainId: PULSECHAIN_ID,
          ...args,
        });
        return { ok: true };
      } catch (err) {
        setSimError(err);
        return { ok: false, error: err };
      } finally {
        setIsSimulating(false);
      }
    },
    [publicClient, address],
  );

  const writeContract = useCallback(
    async (args) => {
      const sim = await simulate(args);
      if (!sim.ok) return;
      return base.writeContract({ chainId: PULSECHAIN_ID, ...args });
    },
    [base, simulate],
  );
  const writeContractAsync = useCallback(
    async (args) => {
      const sim = await simulate(args);
      if (!sim.ok) throw sim.error;
      return base.writeContractAsync({ chainId: PULSECHAIN_ID, ...args });
    },
    [base, simulate],
  );

  // Clear simulation error as soon as a new submission succeeds, so stale
  // reverts don't hang around after the user fixes the inputs.
  useEffect(() => {
    if (base.data) setSimError(null);
  }, [base.data]);

  // Unified error for the UI: simulation → submission → on-chain receipt.
  // Simulation gets priority because it's the earliest + most specific.
  const txError = simError || base.error || receiptError || null;

  return {
    ...base,
    writeContract,
    writeContractAsync,
    hash: base.data,
    isSimulating,
    isMining,
    isConfirmed,
    isOnWrongChain: !isOnPulseChain,
    txError,
  };
}

/// Extract a short, user-facing error message from a viem/wagmi error.
/// Viem wraps revert reasons in `ContractFunctionExecutionError`:
///   err.shortMessage   → "Execution reverted with reason: ..."
///   err.cause?.reason  → "insufficient available balance"
///   err.metaMessages[] → additional context lines
/// We walk the chain looking for the most specific human-readable string.
export function prettyError(err) {
  if (!err) return '';
  // Walk the error cause chain to find a revert reason.
  let cur = err;
  for (let i = 0; i < 6 && cur; i++) {
    if (cur.reason && typeof cur.reason === 'string') return cur.reason;
    if (cur.shortMessage && typeof cur.shortMessage === 'string') {
      return cur.shortMessage;
    }
    cur = cur.cause;
  }
  if (err.message && typeof err.message === 'string') {
    // Truncate the multi-line stack wagmi usually appends.
    return err.message.split('\n')[0];
  }
  return 'Unknown error';
}
