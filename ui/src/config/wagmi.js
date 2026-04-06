import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'wagmi';

const pulsechain = {
  id: 369,
  name: 'PulseChain',
  nativeCurrency: { name: 'Pulse', symbol: 'PLS', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://rpc.pulsechain.com'] },
  },
  blockExplorers: {
    default: { name: 'Otterscan', url: 'https://otter.pulsechain.com' },
  },
};

export const config = getDefaultConfig({
  appName: 'Cabal DAO',
  projectId: 'cabal-dao-placeholder', // Replace with WalletConnect project ID
  chains: [pulsechain],
  transports: {
    [pulsechain.id]: http('https://rpc.pulsechain.com'),
  },
});
