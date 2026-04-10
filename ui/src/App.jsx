import { useState, useEffect } from 'react';
import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from 'wagmi';
import Staking from './components/Staking.jsx';
import Treasury from './components/Treasury.jsx';
import TokenInfo from './components/TokenInfo.jsx';
import Proposals from './components/Proposals.jsx';
import './App.css';

const PULSECHAIN_ID = 369;

function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected && address) {
    return (
      <button onClick={() => disconnect()}>
        {address.slice(0, 6)}...{address.slice(-4)}
      </button>
    );
  }

  const injected = connectors.find((c) => c.id === 'injected') || connectors[0];
  return (
    <button onClick={() => connect({ connector: injected })} disabled={isPending}>
      {isPending ? 'Connecting…' : 'Connect Wallet'}
    </button>
  );
}

/// Shown when the wallet is connected to the wrong chain (typically Ethereum
/// because that's where MetaMask defaults). Auto-attempts the switch, and
/// also renders an explicit button in case auto-switch is rejected.
function WrongChainBanner() {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending, error } = useSwitchChain();

  const wrong = isConnected && chainId !== PULSECHAIN_ID;

  useEffect(() => {
    if (wrong && switchChain) {
      try { switchChain({ chainId: PULSECHAIN_ID }); } catch { /* ignore */ }
    }
  }, [wrong, switchChain]);

  if (!wrong) return null;
  return (
    <div className="wrong-chain-banner">
      <strong>Wrong network:</strong> your wallet is on chain {chainId}. Cabal DAO lives on PulseChain (369).
      <button
        onClick={() => switchChain({ chainId: PULSECHAIN_ID })}
        disabled={isPending}
        style={{ marginLeft: 12 }}
      >
        {isPending ? 'Switching…' : 'Switch to PulseChain'}
      </button>
      {error && <div style={{ marginTop: 6, fontSize: 12, opacity: 0.8 }}>If the switch is rejected, add PulseChain (chainId 369, RPC https://rpc.pulsechain.com) in your wallet first.</div>}
    </div>
  );
}

const TABS = [
  { key: 'token', label: 'Token' },
  { key: 'staking', label: 'Staking' },
  { key: 'dao', label: 'DAO' },
];

function App() {
  const [activeTab, setActiveTab] = useState('token');

  return (
    <>
      <header className="app-header">
        <h1>Cabal DAO</h1>
        <ConnectButton />
      </header>

      <WrongChainBanner />

      <nav className="tab-bar">
        {TABS.map((tab) => (
          <button
            key={tab.key}
            className={`tab-pill${activeTab === tab.key ? ' tab-pill--active' : ''}`}
            onClick={() => setActiveTab(tab.key)}
          >
            {tab.label}
          </button>
        ))}
      </nav>

      <div className="sections">
        {activeTab === 'token' && <TokenInfo />}
        {activeTab === 'staking' && <Staking />}
        {activeTab === 'dao' && (
          <>
            <Treasury />
            <Proposals />
          </>
        )}
      </div>
    </>
  );
}

export default App;
