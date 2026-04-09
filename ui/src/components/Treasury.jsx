import { useReadContract } from '../hooks/usePls.js';
import { formatEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI } from '../config/abis.js';
import TokenIcon from './TokenIcon.jsx';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;

export default function Treasury() {
  const { data: availableBalance } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'availableBalance',
  });
  const { data: lockedAmount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'lockedAmount',
  });
  const { data: votingPeriod } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'votingPeriod',
  });
  const { data: quorumBps } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'quorumBps',
  });
  const { data: dexRouter } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'dexRouter',
  });
  const { data: topStakerCount } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'topStakerCount',
  });
  const { data: totalStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalStaked',
  });

  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };

  const votingDays = votingPeriod ? `${Number(votingPeriod) / 86400} days` : '...';
  const quorumPct = quorumBps ? `${Number(quorumBps) / 100}%` : '...';
  const quorumTokens = (quorumBps && totalStaked)
    ? Number(formatEther(totalStaked * quorumBps / 10000n)).toLocaleString(undefined, { maximumFractionDigits: 0 })
    : '...';

  return (
    <div className="card">
      <h2>Treasury & DAO</h2>
      <p className="help-text">
        Treasury funds come from the Dev tax and can only be spent via DAO proposals. All parameters are on-chain.
      </p>

      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Available</span>
          <span className="stat-value highlight-green"><TokenIcon symbol="WPLS" />{fmt(availableBalance)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Locked</span>
          <span className="stat-value"><TokenIcon symbol="WPLS" />{fmt(lockedAmount)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Voting Period</span>
          <span className="stat-value">{votingDays}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Quorum</span>
          <span className="stat-value">{quorumPct} ({quorumTokens})</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Min to Propose</span>
          <span className="stat-value">Top {topStakerCount !== undefined ? Number(topStakerCount).toString() : '…'}</span>
        </div>
      </div>

      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Contracts</h3>
      <div className="address-grid">
        <div className="address-row">
          <span className="stat-label">DAO</span>
          <a href={`https://otter.pulsechain.com/address/${daoAddr}`} target="_blank" rel="noopener noreferrer" className="address-link">{daoAddr}</a>
        </div>
        <div className="address-row">
          <span className="stat-label">Vault</span>
          <a href={`https://otter.pulsechain.com/address/${vaultAddr}`} target="_blank" rel="noopener noreferrer" className="address-link">{vaultAddr}</a>
        </div>
        <div className="address-row">
          <span className="stat-label">Token</span>
          <a href={`https://otter.pulsechain.com/address/${ADDRESSES.stakeToken}`} target="_blank" rel="noopener noreferrer" className="address-link">{ADDRESSES.stakeToken}</a>
        </div>
        {dexRouter && (
          <div className="address-row">
            <span className="stat-label">Router</span>
            <a href={`https://otter.pulsechain.com/address/${dexRouter}`} target="_blank" rel="noopener noreferrer" className="address-link">{dexRouter}</a>
          </div>
        )}
      </div>
    </div>
  );
}
