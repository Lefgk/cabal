// Wagmi read hooks pinned to PulseChain (chainId 369).
//
// Rationale: `useReadContract` / `useReadContracts` default to the wallet's
// currently connected chain. If a user opens the app while MetaMask is on
// Ethereum, wagmi tries to read our contracts on chain 1 — they don't exist
// there, so every field shows "…" forever. Pinning the reads here forces
// all on-chain reads to hit PulseChain regardless of wallet state.
//
// Write hooks (useWriteContract / useSwitchChain) are unaffected: users
// still must switch their wallet to chain 369 before any transaction can
// be signed. `WrongChainBanner` in App.jsx handles that prompt.

import {
  useReadContract as useWagmiReadContract,
  useReadContracts as useWagmiReadContracts,
} from 'wagmi';
import { PULSECHAIN_ID } from '../config/wagmi.js';

export function useReadContract(args) {
  return useWagmiReadContract({ ...args, chainId: PULSECHAIN_ID });
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
