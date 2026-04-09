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
} from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect } from 'react';
import { PULSECHAIN_ID } from '../config/wagmi.js';

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

/// Drop-in replacement for `useWriteContract` that:
///   1. pins every call to PulseChain (wagmi will refuse to broadcast on
///      any other chain and will prompt the wallet to switch),
///   2. watches the tx receipt and, once it confirms, invalidates the
///      whole react-query cache so every `useReadContract` auto-refetches.
///      This means staking / balance / proposal lists update as soon as
///      any transaction mines, with no manual refresh.
/// Also exposes:
///   - `hash`       : last submitted tx hash
///   - `isMining`   : submitted but not yet mined
///   - `isConfirmed`: mined successfully at least once this session
///   - `isOnWrongChain`: wallet is connected to a chain ≠ 369
export function useSafeWriteContract() {
  const base = useWagmiWriteContract();
  const isOnPulseChain = useIsPulseChain();
  const queryClient = useQueryClient();

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

  const writeContract = useCallback(
    (args) => base.writeContract({ chainId: PULSECHAIN_ID, ...args }),
    [base],
  );
  const writeContractAsync = useCallback(
    (args) => base.writeContractAsync({ chainId: PULSECHAIN_ID, ...args }),
    [base],
  );

  // Combine submission errors (from wallet rejection / simulation / etc)
  // with receipt errors (the tx actually reverted on-chain). Callers get
  // one field to render.
  const txError = base.error || receiptError || null;

  return {
    ...base,
    writeContract,
    writeContractAsync,
    hash: base.data,
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
