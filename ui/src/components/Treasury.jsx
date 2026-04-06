import { useReadContract } from 'wagmi';
import { formatEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI, ERC20_ABI } from '../config/abis.js';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;
const WPLS_ADDR = '0xA1077a294dDE1B09bB078844df40758a5D0f9a27';

export default function Treasury() {
  // Treasury balance
  const { data: availableBalance } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'availableBalance',
  });
  const { data: lockedAmount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'lockedAmount',
  });
  const { data: totalWplsBalance } = useReadContract({
    address: WPLS_ADDR, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [daoAddr],
  });

  // DAO config
  const { data: votingPeriod } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'votingPeriod',
  });
  const { data: quorumBps } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'quorumBps',
  });
  const { data: proposalCount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'proposalCount',
  });
  const { data: dexRouter } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'dexRouter',
  });

  // Vault config
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
      <h2>Treasury & DAO Config</h2>
      <p className="help-text">
        The Treasury holds WPLS collected from the 1% Dev/Treasury tax on every buy and sell. These funds can only be spent through DAO proposals — no single person can withdraw. All parameters below are set on-chain and can only be changed through governance.
      </p>

      {/* Treasury balances */}
      <h3 style={{ marginTop: 12, marginBottom: 4 }}>Treasury Balance</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>Available = funds that can be used in new proposals. Locked = funds reserved for active/passed proposals not yet executed.</p>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Available</span>
          <span className="stat-value highlight-green">{fmt(availableBalance)} WPLS</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Locked (proposals)</span>
          <span className="stat-value">{fmt(lockedAmount)} WPLS</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Held</span>
          <span className="stat-value">{fmt(totalWplsBalance)} WPLS</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Proposals</span>
          <span className="stat-value">{proposalCount !== undefined ? Number(proposalCount).toString() : '...'}</span>
        </div>
      </div>

      {/* Governance parameters */}
      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Governance Parameters</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>These rules govern how proposals work. Voting period is how long a vote stays open. Quorum is the minimum percentage of staked tokens that must vote for a proposal to pass. Only the top stakers can create proposals.</p>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Voting Period</span>
          <span className="stat-value">{votingDays}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Quorum Required</span>
          <span className="stat-value">{quorumPct} of staked</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Quorum (tokens)</span>
          <span className="stat-value">{quorumTokens}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Min to Propose</span>
          <span className="stat-value">Top {topStakerCount !== undefined ? Number(topStakerCount).toString() : '...'} staker</span>
        </div>
      </div>

      {/* Contract addresses */}
      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Contract Addresses</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>All contracts are deployed on PulseChain. Click any address to view it on Otterscan.</p>
      <div className="address-grid">
        <div className="address-row">
          <span className="stat-label">Treasury DAO</span>
          <a href={`https://otter.pulsechain.com/address/${daoAddr}`} target="_blank" rel="noopener noreferrer" className="address-link">{daoAddr}</a>
        </div>
        <div className="address-row">
          <span className="stat-label">Staking Vault</span>
          <a href={`https://otter.pulsechain.com/address/${vaultAddr}`} target="_blank" rel="noopener noreferrer" className="address-link">{vaultAddr}</a>
        </div>
        <div className="address-row">
          <span className="stat-label">Token</span>
          <a href={`https://otter.pulsechain.com/address/${ADDRESSES.stakeToken}`} target="_blank" rel="noopener noreferrer" className="address-link">{ADDRESSES.stakeToken}</a>
        </div>
        {dexRouter && (
          <div className="address-row">
            <span className="stat-label">DEX Router</span>
            <a href={`https://otter.pulsechain.com/address/${dexRouter}`} target="_blank" rel="noopener noreferrer" className="address-link">{dexRouter}</a>
          </div>
        )}
      </div>
    </div>
  );
}
