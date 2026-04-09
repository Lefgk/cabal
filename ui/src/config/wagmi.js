import { createConfig, http, fallback } from 'wagmi';
import { injected } from 'wagmi/connectors';

const pulsechain = {
  id: 369,
  name: 'PulseChain',
  nativeCurrency: { name: 'Pulse', symbol: 'PLS', decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        'https://rpc.pulsechain.com',
        'https://rpc-pulsechain.g4mm4.io',
        'https://pulsechain-rpc.publicnode.com',
      ],
    },
  },
  blockExplorers: {
    default: { name: 'Otterscan', url: 'https://otter.pulsechain.com' },
  },
  contracts: {
    multicall3: {
      address: '0xcA11bde05977b3631167028862bE2a173976CA11',
      blockCreated: 14353601,
    },
  },
};

export const config = createConfig({
  chains: [pulsechain],
  connectors: [injected()],
  transports: {
    [pulsechain.id]: fallback(
      [
        http('https://rpc.pulsechain.com', { batch: true }),
        http('https://rpc-pulsechain.g4mm4.io', { batch: true }),
        http('https://pulsechain-rpc.publicnode.com', { batch: true }),
      ],
      { rank: false },
    ),
  },
});
