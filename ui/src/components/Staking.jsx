import { useState } from 'react';
import { useAccount, useReadContract, useWriteContract } from 'wagmi';
import { formatEther, parseEther, maxUint256 } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { STAKING_VAULT_ABI, ERC20_ABI } from '../config/abis.js';

const vaultAddr = ADDRESSES.stakingVault;
const tokenAddr = ADDRESSES.stakeToken;
const SECONDS_PER_YEAR = 365.25 * 24 * 3600;

function formatCountdown(seconds) {
  if (seconds <= 0) return 'Ended';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export default function Staking() {
  const { address } = useAccount();
  const [stakeAmount, setStakeAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');
  const [showTopStakers, setShowTopStakers] = useState(false);

  const { writeContract, isPending: isWriting } = useWriteContract();

  // Global reads (no wallet needed)
  const { data: totalStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalStaked',
  });
  const { data: rewardRate } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'rewardRate',
  });
  const { data: periodFinish } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'periodFinish',
  });
  const { data: rewardsDuration } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'rewardsDuration',
  });
  const { data: getRewardForDuration } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'getRewardForDuration',
  });
  const { data: totalStakers } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalStakers',
  });
  const { data: topStakers } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'getTopStakers',
  });
  const { data: rewardsTokenAddr } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'rewardsToken',
  });
  const { data: rewardsTokenSymbol } = useReadContract({
    address: rewardsTokenAddr, abi: ERC20_ABI, functionName: 'symbol',
    query: { enabled: !!rewardsTokenAddr },
  });
  const { data: stakeTokenSymbol } = useReadContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'symbol',
  });

  // User-specific reads
  const { data: userStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'stakedBalance',
    args: [address], query: { enabled: !!address },
  });
  const { data: earnedRaw } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'earned',
    args: [address], query: { enabled: !!address },
  });
  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address], query: { enabled: !!address },
  });
  const { data: allowance } = useReadContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'allowance',
    args: [address, vaultAddr], query: { enabled: !!address },
  });
  const { data: tokenBalance } = useReadContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [address], query: { enabled: !!address },
  });

  // Derived values
  const now = Math.floor(Date.now() / 1000);
  const timeLeft = periodFinish ? Number(periodFinish) - now : 0;
  const isActive = timeLeft > 0;
  const rwdSymbol = rewardsTokenSymbol || 'RWD';
  const stkSymbol = stakeTokenSymbol || 'TOKEN';

  // APR: (rewardRate * SECONDS_PER_YEAR / totalStaked) * 100
  // This is a simple projection — assumes 1:1 value between stake and reward token
  const apr = (() => {
    if (!rewardRate || !totalStaked || totalStaked === 0n) return null;
    const ratePerYear = Number(formatEther(rewardRate)) * SECONDS_PER_YEAR;
    const staked = Number(formatEther(totalStaked));
    if (staked === 0) return null;
    return (ratePerYear / staked) * 100;
  })();

  // User pool share %
  const poolShare = (() => {
    if (!userStaked || !totalStaked || totalStaked === 0n) return null;
    return (Number(formatEther(userStaked)) / Number(formatEther(totalStaked))) * 100;
  })();

  // Duration label
  const durationLabel = rewardsDuration ? `${Number(rewardsDuration) / 86400}d` : '...';

  const needsApproval = (() => {
    if (!stakeAmount || !allowance) return true;
    try { return parseEther(stakeAmount) > allowance; } catch { return true; }
  })();

  const handleApprove = () => {
    writeContract({ address: tokenAddr, abi: ERC20_ABI, functionName: 'approve', args: [vaultAddr, maxUint256] });
  };
  const handleStake = () => {
    if (!stakeAmount) return;
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'stake', args: [parseEther(stakeAmount)] });
    setStakeAmount('');
  };
  const handleWithdraw = () => {
    if (!withdrawAmount) return;
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'withdraw', args: [parseEther(withdrawAmount)] });
    setWithdrawAmount('');
  };
  const handleClaim = () => {
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'getReward' });
  };
  const handleExit = () => {
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'exit' });
  };

  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };

  return (
    <div className="card">
      <div className="section-header">
        <h2>Staking</h2>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {isTop && <span className="top-staker-badge">Top Staker</span>}
          <span className={`badge ${isActive ? 'badge-active' : 'badge-defeated'}`}>
            {isActive ? 'Active' : 'Inactive'}
          </span>
        </div>
      </div>

      <p className="help-text">
        Stake {stkSymbol} to earn {rwdSymbol}. Rewards drip linearly over {durationLabel}. Top 100 stakers can create DAO proposals. No lock-up — withdraw anytime.
      </p>

      {apr !== null && (
        <div className="apr-banner">
          <span className="apr-label">Projected APR</span>
          <span className="apr-value">{apr.toLocaleString(undefined, { maximumFractionDigits: 2 })}%</span>
        </div>
      )}

      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Total Staked</span>
          <span className="stat-value">{fmt(totalStaked)} {stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Stakers</span>
          <span className="stat-value">{totalStakers !== undefined ? Number(totalStakers).toLocaleString() : '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">This Period</span>
          <span className="stat-value">{fmt(getRewardForDuration)} {rwdSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Ends In</span>
          <span className="stat-value">{isActive ? formatCountdown(timeLeft) : '—'}</span>
        </div>
      </div>

      {/* User stats — always shown, empty when disconnected */}
      <h3 style={{ marginTop: 20, marginBottom: 8 }}>Your Position</h3>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Staked {address && poolShare !== null ? `(${poolShare.toFixed(2)}%)` : ''}</span>
          <span className="stat-value">{address ? fmt(userStaked) : '—'} {stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Earned</span>
          <span className="stat-value highlight-green">{address ? fmt(earnedRaw) : '—'} {rwdSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Wallet</span>
          <span className="stat-value">{address ? fmt(tokenBalance) : '—'} {stkSymbol}</span>
        </div>
      </div>

      <div className="input-group" style={{ marginTop: 16 }}>
        <input type="text" placeholder="Amount to stake" value={stakeAmount} onChange={(e) => setStakeAmount(e.target.value)} disabled={!address} />
        {needsApproval ? (
          <button onClick={handleApprove} disabled={!address || isWriting}>Approve</button>
        ) : (
          <button onClick={handleStake} disabled={!address || isWriting || !stakeAmount}>Stake</button>
        )}
      </div>

      <div className="input-group">
        <input type="text" placeholder="Amount to withdraw" value={withdrawAmount} onChange={(e) => setWithdrawAmount(e.target.value)} disabled={!address} />
        <button onClick={handleWithdraw} disabled={!address || isWriting || !withdrawAmount}>Withdraw</button>
      </div>

      <div className="input-group">
        <button className="btn-green" onClick={handleClaim} disabled={!address || isWriting}>Claim Rewards</button>
        <button className="btn-red" onClick={handleExit} disabled={!address || isWriting}>Exit (Withdraw All + Claim)</button>
      </div>

      {!address && (
        <p className="help-text" style={{ marginTop: 8 }}>Connect wallet to stake.</p>
      )}

      {/* Top Stakers */}
      {topStakers && topStakers.length > 0 && (
        <div style={{ marginTop: 20 }}>
          <button className="btn-link" onClick={() => setShowTopStakers(!showTopStakers)}>
            {showTopStakers ? 'Hide' : 'Show'} Top Stakers ({topStakers.length})
          </button>
          {showTopStakers && (
            <div className="top-stakers-list">
              {topStakers.map((addr, i) => (
                <div key={addr} className="top-staker-item">
                  <span className="rank">#{i + 1}</span>
                  <a href={`https://otter.pulsechain.com/address/${addr}`} target="_blank" rel="noopener noreferrer" className="address-link">
                    {addr}
                  </a>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
