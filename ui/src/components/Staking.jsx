import { useState } from 'react';
import { useAccount, useReadContract, useWriteContract } from 'wagmi';
import { formatEther, formatUnits, parseEther, maxUint256 } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { STAKING_VAULT_ABI, ERC20_ABI } from '../config/abis.js';
import TokenIcon from './TokenIcon.jsx';

const vaultAddr = ADDRESSES.stakingVault;
const tokenAddr = ADDRESSES.stakeToken;

// Display override: native PulseChain HEX reports its on-chain symbol as
// "HEX", but we present it as "pHEX" throughout the UI to make it unambiguous
// vs eHEX and to match the client spec.
function displaySymbol(raw) {
  if (!raw) return raw;
  if (raw === 'HEX') return 'pHEX';
  return raw;
}

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
  const { data: rewardsTokenDecimals } = useReadContract({
    address: rewardsTokenAddr, abi: ERC20_ABI, functionName: 'decimals',
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
  const rwdSymbol = displaySymbol(rewardsTokenSymbol) || 'RWD';
  const stkSymbol = stakeTokenSymbol || 'TOKEN';
  // Reward token decimals (pHEX = 8, NOT 18). We MUST NOT use formatEther
  // for reward amounts — it would under-report by 10^10.
  const rwdDec = rewardsTokenDecimals !== undefined ? Number(rewardsTokenDecimals) : 18;

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

  // Stake-token amounts (always 18d)
  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };
  // Reward-token amounts — uses the on-chain decimals (pHEX = 8)
  const fmtRwd = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatUnits(val, rwdDec)).toLocaleString(undefined, { maximumFractionDigits: 4 });
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

      {isActive && getRewardForDuration && (
        <div className="apr-banner">
          <span className="apr-label">Current {durationLabel} Emission</span>
          <span className="apr-value">
            {fmtRwd(getRewardForDuration)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      )}

      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Total Staked</span>
          <span className="stat-value">{fmt(totalStaked)} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Stakers</span>
          <span className="stat-value">{totalStakers !== undefined ? Number(totalStakers).toLocaleString() : '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">This Period</span>
          <span className="stat-value">{fmtRwd(getRewardForDuration)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
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
          <span className="stat-value">{address ? fmt(userStaked) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Earned</span>
          <span className="stat-value highlight-green">{address ? fmtRwd(earnedRaw) : '—'} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Wallet</span>
          <span className="stat-value">{address ? fmt(tokenBalance) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
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
