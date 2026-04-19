import { useState, useEffect } from 'react';
import { useAccount } from 'wagmi';
import {
  useReadContract,
  useSafeWriteContract,
  useBalance,
  useConnectedChain,
  prettyError,
} from '../hooks/usePls.js';
import { formatEther, formatUnits, parseEther, maxUint256 } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { STAKING_VAULT_ABI, ERC20_ABI } from '../config/abis.js';
import TokenIcon from './TokenIcon.jsx';

const vaultAddr = ADDRESSES.stakingVault;
const tokenAddr = ADDRESSES.stakeToken;

// Lock tier metadata for the UI selector
const LOCK_TIERS = [
  { duration: 90 * 86400, label: '90 days', multiplier: '1.5x', bps: 15000 },
  { duration: 180 * 86400, label: '180 days', multiplier: '2.0x', bps: 20000 },
  { duration: 365 * 86400, label: '1 year', multiplier: '3.0x', bps: 30000 },
  { duration: 730 * 86400, label: '2 years', multiplier: '4.0x', bps: 40000 },
  { duration: 1825 * 86400, label: '5 years', multiplier: '6.0x', bps: 60000 },
  { duration: 3650 * 86400, label: '10 years', multiplier: '10.0x', bps: 100000 },
];

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

function formatDaysRemaining(unlockTime, now) {
  const secs = Number(unlockTime) - now;
  if (secs <= 0) return 'Expired';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  if (d > 0) return `${d}d ${h}h`;
  return `${h}h`;
}

export default function Staking() {
  const { address } = useAccount();
  const [tab, setTab] = useState('flex');
  const [stakeAmount, setStakeAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');
  const [lockAmount, setLockAmount] = useState('');
  const [selectedTier, setSelectedTier] = useState(0);
  const [showTopStakers, setShowTopStakers] = useState(false);

  const {
    writeContract,
    isPending: isWriting,
    isSimulating,
    isMining,
    isOnWrongChain,
    txError,
  } = useSafeWriteContract();
  const busy = isWriting || isSimulating || isMining;
  const chain = useConnectedChain();

  // Global reads
  const { data: totalStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalRawStaked',
  });
  const { data: totalEffective } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalEffectiveStaked',
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
  const { data: userFlexBalance } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'flexBalance',
    args: [address], query: { enabled: !!address },
  });
  const { data: userEffective } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'effectiveBalance',
    args: [address], query: { enabled: !!address },
  });
  const { data: userStakedTotal } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'stakedBalance',
    args: [address], query: { enabled: !!address },
  });
  const { data: earnedRaw } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'earned',
    args: [address], query: { enabled: !!address, refetchInterval: 5000 },
  });
  const { data: userLocks } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'getUserLocks',
    args: [address], query: { enabled: !!address, refetchInterval: 10000 },
  });
  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address], query: { enabled: !!address },
  });
  const { data: voteLockEndRaw } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'voteLockEnd',
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
  const { data: vaultPlsBal } = useBalance({
    address: vaultAddr,
    query: { refetchInterval: 10000 },
  });
  const { data: totalOwed } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalOwed',
  });
  const { data: vaultPhexBal } = useReadContract({
    address: rewardsTokenAddr, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [vaultAddr], query: { enabled: !!rewardsTokenAddr },
  });

  // Tick
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
  const timeLeft = periodFinish ? Number(periodFinish) - now : 0;
  const isActive = timeLeft > 0;
  const rwdSymbol = displaySymbol(rewardsTokenSymbol) || 'RWD';
  const stkSymbol = stakeTokenSymbol || 'TOKEN';
  const rwdDec = rewardsTokenDecimals !== undefined ? Number(rewardsTokenDecimals) : 18;

  // Pool share by effective weight
  const poolShare = (() => {
    if (!userEffective || !totalEffective || totalEffective === 0n) return null;
    return (Number(formatEther(userEffective)) / Number(formatEther(totalEffective))) * 100;
  })();

  const durationLabel = rewardsDuration ? `${Number(rewardsDuration) / 86400}d` : '...';

  // Vote lock
  const voteLockEnd = voteLockEndRaw ? Number(voteLockEndRaw) : 0;
  const voteLocked = voteLockEnd > 0 && now <= voteLockEnd;
  const voteLockDate = voteLocked ? new Date(voteLockEnd * 1000).toLocaleString() : null;

  // Locked balance = total - flex
  const userLockedBalance = (() => {
    if (userStakedTotal === undefined || userFlexBalance === undefined) return undefined;
    return userStakedTotal - userFlexBalance;
  })();

  // Approval check
  const needsApprovalFor = (amt) => {
    if (!amt) return false;
    let wanted;
    try { wanted = parseEther(amt); } catch { return false; }
    return (allowance ?? 0n) < wanted;
  };

  const needsApproval = needsApprovalFor(tab === 'flex' ? stakeAmount : lockAmount);

  // Handlers
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
  const handleProcess = () => {
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'processRewards' });
  };
  const handleStakeLocked = () => {
    if (!lockAmount) return;
    const tier = LOCK_TIERS[selectedTier];
    writeContract({
      address: vaultAddr,
      abi: STAKING_VAULT_ABI,
      functionName: 'stakeLocked',
      args: [parseEther(lockAmount), BigInt(tier.duration)],
    });
    setLockAmount('');
  };
  const handleUnlock = (lockId) => {
    writeContract({
      address: vaultAddr,
      abi: STAKING_VAULT_ABI,
      functionName: 'unlock',
      args: [[BigInt(lockId)]],
    });
  };
  const handleUnlockAllExpired = () => {
    if (!userLocks) return;
    const expiredIds = [];
    for (let i = userLocks.length - 1; i >= 0; i--) {
      if (Number(userLocks[i].unlockTime) <= now) {
        expiredIds.push(BigInt(i));
      }
    }
    if (expiredIds.length === 0) return;
    // Already in descending order since we iterate backwards
    writeContract({
      address: vaultAddr,
      abi: STAKING_VAULT_ABI,
      functionName: 'unlock',
      args: [expiredIds],
    });
  };

  // Formatting
  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };
  const fmtRwd = (val, frac = 4) => {
    if (val === undefined || val === null) return '...';
    return Number(formatUnits(val, rwdDec)).toLocaleString(undefined, { maximumFractionDigits: frac });
  };
  const fmtExact = (val, decimals, places = 18) => {
    if (val === undefined || val === null) return '...';
    const s = formatUnits(val, decimals);
    const [whole, fracIn = ''] = s.split('.');
    const frac = (fracIn + '0'.repeat(places)).slice(0, places);
    const wholeFmt = Number(whole).toLocaleString();
    return `${wholeFmt}.${frac}`;
  };
  const fmtRwdExact = (val, places = 8) => fmtExact(val, rwdDec, places);

  const hasExpiredLocks = userLocks && userLocks.some(lk => Number(lk.unlockTime) <= now);

  return (
    <div className="card">
      <div className="section-header">
        <h2>Staking</h2>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {chain.isConnected && (
            <span
              className={`badge ${chain.isPulseChain ? 'badge-active' : 'badge-defeated'}`}
              title={
                chain.isPulseChain
                  ? `Wallet on ${chain.chainName} (${chain.chainId})`
                  : `Wallet on ${chain.chainName} (${chain.chainId}) — writes will be rejected. Switch to PulseChain (369).`
              }
            >
              {chain.isPulseChain ? '● ' : '⚠ '}{chain.chainName}
            </span>
          )}
          {isTop && <span className="top-staker-badge">Top Staker</span>}
          <span className={`badge ${isActive ? 'badge-active' : 'badge-defeated'}`}>
            {isActive ? 'Active' : 'Inactive'}
          </span>
        </div>
      </div>

      <p className="help-text">
        Stake {stkSymbol} to earn {rwdSymbol}. Flex stake (1x, 1% withdraw fee) or lock for higher
        multipliers (up to 10x). Rewards drip linearly over {durationLabel}. Top 100 stakers
        (by effective weight) can create DAO proposals.
      </p>

      {isActive && getRewardForDuration && (
        <div className="apr-banner">
          <span className="apr-label">Current {durationLabel} Emission</span>
          <span className="apr-value">
            {fmtRwd(getRewardForDuration, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      )}

      {/* Pending-swap banner */}
      <div
        className="apr-banner"
        style={{ background: 'linear-gradient(135deg, rgba(59,130,246,0.15), rgba(124,58,237,0.10))', borderColor: 'rgba(59,130,246,0.3)' }}
        title="Raw PLS sitting on the vault from recent sell taxes."
      >
        <span className="apr-label">Pending swap → {rwdSymbol}</span>
        <span className="apr-value" style={{ color: 'var(--blue)', fontSize: 14, wordBreak: 'break-all' }}>
          {vaultPlsBal ? fmtExact(vaultPlsBal.value, 18, 18) : '...'} <TokenIcon symbol="PLS" />PLS
        </span>
        <div style={{ marginTop: 10 }}>
          <button
            className="btn-blue"
            onClick={handleProcess}
            disabled={!address || isWriting || !vaultPlsBal || vaultPlsBal.value === 0n}
            style={{ fontSize: 12, padding: '6px 12px' }}
          >
            Process pending → {rwdSymbol}
          </button>
        </div>
      </div>

      {/* Pool stats */}
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Total Staked</span>
          <span className="stat-value">{fmt(totalStaked)} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Effective</span>
          <span className="stat-value">{fmt(totalEffective)} <TokenIcon symbol={stkSymbol} />eff</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Stakers</span>
          <span className="stat-value">{totalStakers !== undefined ? Number(totalStakers).toLocaleString() : '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Ends In</span>
          <span className="stat-value">{isActive ? formatCountdown(timeLeft) : '—'}</span>
        </div>
      </div>

      {/* Vault Health */}
      <h3 style={{ marginTop: 20, marginBottom: 8 }}>Vault Health</h3>
      <div className="stats-grid">
        <div className="stat-box" title="Total reward tokens held by the vault">
          <span className="stat-label">Vault {rwdSymbol}</span>
          <span className="stat-value">{fmtRwd(vaultPhexBal, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
        </div>
        <div className="stat-box" title="Rewards credited but not yet claimed">
          <span className="stat-label">Unclaimed</span>
          <span className="stat-value">{fmtRwd(totalOwed, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
        </div>
        <div className="stat-box" title="Remaining drip budget">
          <span className="stat-label">Drip Budget</span>
          <span className="stat-value">
            {vaultPhexBal !== undefined && totalOwed !== undefined
              ? fmtRwd(vaultPhexBal > totalOwed ? vaultPhexBal - totalOwed : 0n, rwdDec)
              : '...'} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      </div>

      {/* Summary Panel */}
      <h3 style={{ marginTop: 20, marginBottom: 8 }}>Your Position</h3>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Effective Weight {address && poolShare !== null ? `(${poolShare.toFixed(2)}%)` : ''}</span>
          <span className="stat-value">{address ? fmt(userEffective) : '—'} eff</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Flex Balance</span>
          <span className="stat-value">{address ? fmt(userFlexBalance) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Locked Balance</span>
          <span className="stat-value">{address ? fmt(userLockedBalance) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div className="stat-box" title="Total claimable rewards across all positions">
          <span className="stat-label">Claimable</span>
          <span className="stat-value highlight-green" style={{ fontSize: 13, wordBreak: 'break-all' }}>
            {address ? fmtRwdExact(earnedRaw) : '—'} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      </div>

      {/* Claim All button */}
      <div className="input-group" style={{ marginTop: 12 }}>
        <button className="btn-green" onClick={handleClaim} disabled={!address || busy || isOnWrongChain}>
          Claim All Rewards
        </button>
        <div className="stat-box" style={{ padding: '4px 8px', fontSize: 12 }}>
          <span className="stat-label">Wallet</span>
          <span className="stat-value">{address ? fmt(tokenBalance) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 0, marginTop: 20, borderBottom: '2px solid rgba(255,255,255,0.1)' }}>
        {['flex', 'lock'].map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              flex: 1,
              padding: '10px 16px',
              background: tab === t ? 'rgba(255,255,255,0.08)' : 'transparent',
              border: 'none',
              borderBottom: tab === t ? '2px solid var(--blue, #3b82f6)' : '2px solid transparent',
              color: tab === t ? '#fff' : 'rgba(255,255,255,0.5)',
              cursor: 'pointer',
              fontWeight: tab === t ? 600 : 400,
              fontSize: 14,
              textTransform: 'capitalize',
            }}
          >
            {t === 'flex' ? 'Flex Stake (1x)' : 'Lock Stake (1.5x–10x)'}
          </button>
        ))}
      </div>

      {/* Flex Tab */}
      {tab === 'flex' && (
        <div style={{ marginTop: 16 }}>
          <p className="help-text" style={{ marginBottom: 12 }}>
            Flex staking: 1x multiplier, withdraw anytime with a 1% fee to the DAO treasury.
          </p>

          <div className="input-group">
            <input
              type="text"
              placeholder="Amount to stake"
              value={stakeAmount}
              onChange={(e) => setStakeAmount(e.target.value)}
              disabled={!address}
            />
            {needsApproval ? (
              <button onClick={handleApprove} disabled={!address || busy || isOnWrongChain}>Approve</button>
            ) : (
              <button onClick={handleStake} disabled={!address || busy || isOnWrongChain || !stakeAmount}>Stake</button>
            )}
          </div>

          <div className="input-group">
            <input
              type="text"
              placeholder="Amount to withdraw (1% fee)"
              value={withdrawAmount}
              onChange={(e) => setWithdrawAmount(e.target.value)}
              disabled={!address}
            />
            <button onClick={handleWithdraw} disabled={!address || busy || isOnWrongChain || !withdrawAmount || voteLocked}>
              Withdraw
            </button>
          </div>

          <div className="input-group">
            <button className="btn-red" onClick={handleExit} disabled={!address || busy || isOnWrongChain || voteLocked}>
              Exit (Withdraw All Flex + Claim)
            </button>
          </div>

          {withdrawAmount && (
            <p className="help-text" style={{ marginTop: 4, color: '#eab308', fontSize: 12 }}>
              1% withdraw fee: ~{(() => {
                try { return Number(formatEther(parseEther(withdrawAmount) / 100n)).toLocaleString(undefined, { maximumFractionDigits: 4 }); }
                catch { return '?'; }
              })()} {stkSymbol} goes to DAO treasury.
            </p>
          )}
        </div>
      )}

      {/* Lock Tab */}
      {tab === 'lock' && (
        <div style={{ marginTop: 16 }}>
          <p className="help-text" style={{ marginBottom: 12 }}>
            Lock staking: higher reward multiplier. Early unlock incurs a 30% penalty
            (69% to stakers, 20% burned, 10% DAO, 1% dev).
          </p>

          {/* Tier Selector */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 12 }}>
            {LOCK_TIERS.map((tier, i) => (
              <button
                key={tier.duration}
                onClick={() => setSelectedTier(i)}
                style={{
                  padding: '6px 12px',
                  fontSize: 12,
                  borderRadius: 6,
                  border: selectedTier === i ? '2px solid var(--blue, #3b82f6)' : '1px solid rgba(255,255,255,0.2)',
                  background: selectedTier === i ? 'rgba(59,130,246,0.15)' : 'transparent',
                  color: selectedTier === i ? '#fff' : 'rgba(255,255,255,0.6)',
                  cursor: 'pointer',
                }}
              >
                {tier.label} ({tier.multiplier})
              </button>
            ))}
          </div>

          <div className="input-group">
            <input
              type="text"
              placeholder={`Amount to lock for ${LOCK_TIERS[selectedTier].label}`}
              value={lockAmount}
              onChange={(e) => setLockAmount(e.target.value)}
              disabled={!address}
            />
            {needsApproval ? (
              <button onClick={handleApprove} disabled={!address || busy || isOnWrongChain}>Approve</button>
            ) : (
              <button onClick={handleStakeLocked} disabled={!address || busy || isOnWrongChain || !lockAmount}>
                Lock Stake ({LOCK_TIERS[selectedTier].multiplier})
              </button>
            )}
          </div>

          {lockAmount && (
            <p className="help-text" style={{ marginTop: 4, fontSize: 12 }}>
              Effective weight: {(() => {
                try {
                  const amt = Number(formatEther(parseEther(lockAmount)));
                  const mult = LOCK_TIERS[selectedTier].bps / 10000;
                  return (amt * mult).toLocaleString(undefined, { maximumFractionDigits: 4 });
                } catch { return '?'; }
              })()} eff | Unlock: {LOCK_TIERS[selectedTier].label} | Early penalty: 30%
            </p>
          )}

          {/* Active Locks Table */}
          {userLocks && userLocks.length > 0 && (
            <div style={{ marginTop: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <h4 style={{ margin: 0 }}>Active Locks ({userLocks.length})</h4>
                {hasExpiredLocks && (
                  <button
                    className="btn-green"
                    onClick={handleUnlockAllExpired}
                    disabled={!address || busy || isOnWrongChain || voteLocked}
                    style={{ fontSize: 12, padding: '4px 10px' }}
                  >
                    Unlock All Expired
                  </button>
                )}
              </div>
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', fontSize: 12, borderCollapse: 'collapse' }}>
                  <thead>
                    <tr style={{ borderBottom: '1px solid rgba(255,255,255,0.1)', textAlign: 'left' }}>
                      <th style={{ padding: '6px 8px' }}>#</th>
                      <th style={{ padding: '6px 8px' }}>Amount</th>
                      <th style={{ padding: '6px 8px' }}>Mult</th>
                      <th style={{ padding: '6px 8px' }}>Effective</th>
                      <th style={{ padding: '6px 8px' }}>Time Left</th>
                      <th style={{ padding: '6px 8px' }}>Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {userLocks.map((lk, i) => {
                      const expired = Number(lk.unlockTime) <= now;
                      const mult = Number(lk.multiplier) / 10000;
                      const eff = Number(formatEther(lk.amount)) * mult;
                      return (
                        <tr key={i} style={{ borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
                          <td style={{ padding: '6px 8px' }}>{i}</td>
                          <td style={{ padding: '6px 8px' }}>{fmt(lk.amount)}</td>
                          <td style={{ padding: '6px 8px' }}>{mult}x</td>
                          <td style={{ padding: '6px 8px' }}>{eff.toLocaleString(undefined, { maximumFractionDigits: 2 })}</td>
                          <td style={{ padding: '6px 8px', color: expired ? '#22c55e' : '#eab308' }}>
                            {expired ? 'Expired' : formatDaysRemaining(lk.unlockTime, now)}
                          </td>
                          <td style={{ padding: '6px 8px' }}>
                            <button
                              onClick={() => handleUnlock(i)}
                              disabled={!address || busy || isOnWrongChain || voteLocked}
                              style={{
                                fontSize: 11,
                                padding: '3px 8px',
                                cursor: 'pointer',
                                background: expired ? 'rgba(34,197,94,0.15)' : 'rgba(220,38,38,0.15)',
                                color: expired ? '#22c55e' : '#ef4444',
                                border: `1px solid ${expired ? 'rgba(34,197,94,0.3)' : 'rgba(220,38,38,0.3)'}`,
                                borderRadius: 4,
                              }}
                              title={expired ? 'Unlock expired position (full return)' : 'Early unlock: 30% penalty'}
                            >
                              {expired ? 'Unlock' : 'Early Unlock (30%)'}
                            </button>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Warnings */}
      {voteLocked && (
        <p
          className="help-text"
          style={{
            marginTop: 8,
            padding: '8px 10px',
            border: '1px solid rgba(234,179,8,0.35)',
            background: 'rgba(234,179,8,0.08)',
            borderRadius: 6,
            color: '#eab308',
          }}
        >
          Tokens locked until {voteLockDate} (active vote). You can still stake and claim rewards.
        </p>
      )}
      {!address && (
        <p className="help-text" style={{ marginTop: 8 }}>Connect wallet to stake.</p>
      )}
      {address && isOnWrongChain && (
        <p className="help-text" style={{ marginTop: 8, color: 'var(--danger, #c33)' }}>
          Switch your wallet to PulseChain (369) to stake.
        </p>
      )}
      {isSimulating && (
        <p className="help-text" style={{ marginTop: 8 }}>Simulating transaction…</p>
      )}
      {isMining && (
        <p className="help-text" style={{ marginTop: 8 }}>Waiting for confirmation…</p>
      )}
      {txError && (
        <p
          className="help-text"
          style={{
            marginTop: 8,
            padding: '8px 10px',
            border: '1px solid rgba(220,38,38,0.35)',
            background: 'rgba(220,38,38,0.08)',
            borderRadius: 6,
            color: 'var(--danger, #c33)',
            wordBreak: 'break-word',
          }}
        >
          ⚠ {prettyError(txError)}
        </p>
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
