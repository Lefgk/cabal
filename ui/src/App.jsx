import { useAccount, useConnect, useDisconnect } from 'wagmi';
import Staking from './components/Staking.jsx';
import Treasury from './components/Treasury.jsx';
import TokenInfo from './components/TokenInfo.jsx';
import Proposals from './components/Proposals.jsx';
import './App.css';

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

function App() {
  return (
    <>
      <header className="app-header">
        <h1>Cabal DAO</h1>
        <ConnectButton />
      </header>

      <div className="sections">
        <Staking />
        <Treasury />
        <TokenInfo />
        <Proposals />
      </div>
    </>
  );
}

export default App;
