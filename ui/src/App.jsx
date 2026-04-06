import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useAccount } from 'wagmi';
import Staking from './components/Staking.jsx';
import Treasury from './components/Treasury.jsx';
import Proposals from './components/Proposals.jsx';
import './App.css';

function App() {
  const { isConnected } = useAccount();

  return (
    <>
      <header className="app-header">
        <h1>Cabal DAO</h1>
        <ConnectButton />
      </header>

      <div className="sections">
        <Staking />
        <Treasury />
        <Proposals />
      </div>
    </>
  );
}

export default App;
