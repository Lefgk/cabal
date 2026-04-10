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
  // Poll earned every 5s so the counter ticks up in real time on public RPC
  // (which doesn't push block events reliably).
  const { data: earnedRaw } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'earned',
    args: [address], query: { enabled: !!address, refetchInterval: 5000 },
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
  // Raw PLS sitting on the vault — queued for the next autoProcess swap.
  // Taxes arrive here from buys/sells and stay until the next
  // stake/withdraw/getReward touches the vault. Polled every 10s so
  // users can watch pending taxes grow in real time.
  const { data: vaultPlsBal } = useBalance({
    address: vaultAddr,
    query: { refetchInterval: 10000 },
  });
  // totalOwed = rewards already credited to stakers but not yet claimed.
  const { data: totalOwed } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalOwed',
  });
  // pHEX balance sitting in the vault (dripping + unclaimed + dust).
  const { data: vaultPhexBal } = useReadContract({
    address: rewardsTokenAddr, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [vaultAddr], query: { enabled: !!rewardsTokenAddr },
  });

  // Derived values — tick `now` every second so the countdown updates live
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
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

  // Dust-drip detector: Synthetix-style rewardPerToken uses 1e18 fixed-point
  // scaling, so the per-second delta is `rewardRate * 1e18 / totalStaked`.
  // If that's < 1, integer truncation floors it to 0 and `earned()` stays at
  // 0 for every staker until ~`totalStaked / (rewardRate * 1e18)` seconds
  // have elapsed. Contract is fine — seed is just too small for current
  // stake depth. Flag it so users understand why Claimable isn't ticking.
  const dustDrip = (() => {
    if (!rewardRate || !totalStaked || !isActive) return null;
    if (rewardRate === 0n || totalStaked === 0n) return null;
    const scaled = rewardRate * 10n ** 18n;
    if (scaled >= totalStaked) return null; // tick ≥ 1 wei/sec, healthy
    // Seconds until rewardPerToken ticks up by 1 wei
    const secsPerTick = totalStaked / scaled;
    return { secsPerTick };
  })();

  // Only flag as needing approval when the user has entered a valid amount
  // that exceeds the current allowance. An empty input should NOT force the
  // button to "Approve" when the wallet is already max-approved.
  const needsApproval = (() => {
    if (!stakeAmount) return false;
    let wanted;
    try { wanted = parseEther(stakeAmount); } catch { return false; }
    return (allowance ?? 0n) < wanted;
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
  // Any wallet can fire processRewards() — it's the public keeper hook
  // that folds pending PLS into the drip. Unlike stake/withdraw/getReward,
  // it doesn't require the caller to be a staker, so non-holders can
  // also poke the vault to keep rewards flowing.
  const handleProcess = () => {
    writeContract({ address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'processRewards' });
  };

  // Stake-token amounts (always 18d)
  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };
  // Reward-token amounts — uses the on-chain decimals (pHEX = 8). Default
  // to 4 fraction digits for headline numbers; pass more for the user's
  // live "earned" counter so small drip amounts don't round to zero.
  // When `pad` is true, trailing zeros stay visible so the counter
  // always shows the full decimal column (otherwise `toLocaleString`
  // collapses `0.00000000` down to `0` and you can't see it tick).
  const fmtRwd = (val, frac = 4, pad = false) => {
    if (val === undefined || val === null) return '...';
    return Number(formatUnits(val, rwdDec)).toLocaleString(undefined, {
      maximumFractionDigits: frac,
      minimumFractionDigits: pad ? frac : 0,
    });
  };
  // Fixed-precision string formatter. Uses viem's formatUnits to get an
  // exact decimal string (no JS float rounding), then pads/truncates to
  // `places` fraction digits and adds thousands separators on the integer
  // side. We call this with 18 for the on-screen counters so users can
  // see even the smallest drip movements — pHEX only has 8 real decimals
  // of precision so positions 9–18 will always be trailing zeros, which
  // is expected.
  const fmtExact = (val, decimals, places = 18) => {
    if (val === undefined || val === null) return '...';
    const s = formatUnits(val, decimals);
    const [whole, fracIn = ''] = s.split('.');
    const frac = (fracIn + '0'.repeat(places)).slice(0, places);
    const wholeFmt = Number(whole).toLocaleString();
    return `${wholeFmt}.${frac}`;
  };
  const fmtRwdExact = (val, places = 18) => fmtExact(val, rwdDec, places);

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
        Stake {stkSymbol} to earn {rwdSymbol}. Rewards drip linearly over {durationLabel}. Top 100 stakers can create DAO proposals. No lock-up — withdraw anytime.
      </p>

      {isActive && getRewardForDuration && (
        <div className="apr-banner">
          <span className="apr-label">Current {durationLabel} Emission</span>
          <span className="apr-value">
            {fmtRwd(getRewardForDuration, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      )}

      {/* Dust-drip warning — drip is technically active but rewardRate is so
          small vs totalStaked that `rewardPerToken` integer-divides to 0 and
          Claimable will sit at 0 until enough time elapses for the fixed-point
          math to tick. Standard Synthetix pitfall on under-seeded vaults. */}
      {dustDrip && (
        <div
          className="apr-banner"
          style={{
            background: 'linear-gradient(135deg, rgba(234,179,8,0.15), rgba(249,115,22,0.10))',
            borderColor: 'rgba(234,179,8,0.4)',
          }}
          title="Synthetix-style rewardPerToken uses 1e18 fixed-point scaling. When rewardRate × 1e18 < totalStaked, the per-second delta floors to 0 and earned() stays at 0 until enough seconds elapse to tick the integer. Fix: top up the drip."
        >
          <span className="apr-label" style={{ color: '#eab308' }}>
            ⚠ Drip below precision
          </span>
          <span className="apr-value" style={{ color: '#eab308', fontSize: 13 }}>
            Claimable stuck at 0 — ticks every{' '}
            {dustDrip.secsPerTick >= 86400n
              ? `${Number(dustDrip.secsPerTick / 86400n)}d`
              : dustDrip.secsPerTick >= 3600n
                ? `${Number(dustDrip.secsPerTick / 3600n)}h`
                : `${Number(dustDrip.secsPerTick)}s`}
          </span>
          <span className="apr-note">
            Drip is active and funded, but the reward rate ({rewardRate?.toString()} wei pHEX/sec)
            is too small vs total staked ({fmt(totalStaked)} {stkSymbol}) for Solidity's
            fixed-point math to represent per-second accrual. Counter will remain 0 until
            ~{dustDrip.secsPerTick >= 86400n
              ? `${Number(dustDrip.secsPerTick / 86400n)} day(s)`
              : `${Number(dustDrip.secsPerTick / 3600n)} hour(s)`}{' '}
            from the last notify. Top up the drip with more pHEX to fix.
          </span>
        </div>
      )}

      {/* Pending-swap banner — raw PLS sitting on the vault from recent
          tax forwards. Auto-swaps to pHEX on the next stake/withdraw/
          getReward via the autoProcess modifier. Rendered prominently
          so users can watch the queue grow between triggers. */}
      <div
        className="apr-banner"
        style={{ background: 'linear-gradient(135deg, rgba(59,130,246,0.15), rgba(124,58,237,0.10))', borderColor: 'rgba(59,130,246,0.3)' }}
        title="Raw PLS sitting on the vault from recent sell taxes. On the next stake/withdraw/claim, autoProcess swaps it to pHEX and (if it clears the dust threshold) extends the drip."
      >
        <span className="apr-label">Pending swap → pHEX</span>
        <span className="apr-value" style={{ color: 'var(--blue)', fontSize: 14, wordBreak: 'break-all' }}>
          {vaultPlsBal ? fmtExact(vaultPlsBal.value, 18, 18) : '...'} <TokenIcon symbol="PLS" />PLS
        </span>
        <span className="apr-note">
          Fires automatically on the next stake / withdraw / claim. Needs ≥ 604,800 wei pHEX after swap to restart the drip.
        </span>
        <div style={{ marginTop: 10 }}>
          <button
            className="btn-blue"
            onClick={handleProcess}
            disabled={!address || isWriting || !vaultPlsBal || vaultPlsBal.value === 0n}
            title="Call processRewards() on the vault — public keeper hook that swaps pending PLS to pHEX and extends the drip. Anyone can call this, no stake required."
            style={{ fontSize: 12, padding: '6px 12px' }}
          >
            Process pending → pHEX
          </button>
        </div>
      </div>

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
          <span className="stat-label">Ends In</span>
          <span className="stat-value">{isActive ? formatCountdown(timeLeft) : '—'}</span>
        </div>
      </div>

      <h3 style={{ marginTop: 20, marginBottom: 8 }}>Vault Health</h3>
      <div className="stats-grid">
        <div className="stat-box" title="Total pHEX held by the vault (active drip + unclaimed rewards + dust)">
          <span className="stat-label">Vault {rwdSymbol}</span>
          <span className="stat-value">{fmtRwd(vaultPhexBal, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
        </div>
        <div className="stat-box" title="pHEX already credited to stakers' Claimable balances but not yet withdrawn">
          <span className="stat-label">Unclaimed</span>
          <span className="stat-value">{fmtRwd(totalOwed, rwdDec)} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}</span>
        </div>
        <div className="stat-box" title="pHEX remaining in the active 7-day drip (vault balance minus what's already owed to stakers)">
          <span className="stat-label">Drip Budget</span>
          <span className="stat-value">
            {vaultPhexBal !== undefined && totalOwed !== undefined
              ? fmtRwd(vaultPhexBal > totalOwed ? vaultPhexBal - totalOwed : 0n, rwdDec)
              : '...'} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
      </div>

      {/* User stats — always shown, empty when disconnected */}
      <h3 style={{ marginTop: 20, marginBottom: 8 }}>Your Position</h3>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Staked {address && poolShare !== null ? `(${poolShare.toFixed(2)}%)` : ''}</span>
          <span className="stat-value">{address ? fmt(userStaked) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
        <div
          className="stat-box"
          title="Your claimable rewards right now, at pHEX's native 8-decimal precision. Click 'Claim Rewards' below to withdraw this amount."
        >
          <span className="stat-label">Claimable</span>
          <span
            className="stat-value highlight-green"
            style={{ fontSize: 13, wordBreak: 'break-all' }}
          >
            {address ? fmtRwdExact(earnedRaw, 8) : '—'} <TokenIcon symbol={rwdSymbol} />{rwdSymbol}
          </span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Wallet</span>
          <span className="stat-value">{address ? fmt(tokenBalance) : '—'} <TokenIcon symbol={stkSymbol} />{stkSymbol}</span>
        </div>
      </div>

      <div className="input-group" style={{ marginTop: 16 }}>
        <input type="text" placeholder="Amount to stake" value={stakeAmount} onChange={(e) => setStakeAmount(e.target.value)} disabled={!address} />
        {needsApproval ? (
          <button onClick={handleApprove} disabled={!address || busy || isOnWrongChain}>Approve</button>
        ) : (
          <button onClick={handleStake} disabled={!address || busy || isOnWrongChain || !stakeAmount}>Stake</button>
        )}
      </div>

      <div className="input-group">
        <input type="text" placeholder="Amount to withdraw" value={withdrawAmount} onChange={(e) => setWithdrawAmount(e.target.value)} disabled={!address} />
        <button onClick={handleWithdraw} disabled={!address || busy || isOnWrongChain || !withdrawAmount}>Withdraw</button>
      </div>

      <div className="input-group">
        <button className="btn-green" onClick={handleClaim} disabled={!address || busy || isOnWrongChain}>Claim Rewards</button>
        <button className="btn-red" onClick={handleExit} disabled={!address || busy || isOnWrongChain}>Exit (Withdraw All + Claim)</button>
      </div>

      {!address && (
        <p className="help-text" style={{ marginTop: 8 }}>Connect wallet to stake.</p>
      )}
      {address && isOnWrongChain && (
        <p className="help-text" style={{ marginTop: 8, color: 'var(--danger, #c33)' }}>
          Switch your wallet to PulseChain (369) to stake. Currently on{' '}
          {chain.chainName || 'an unknown chain'}.
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
          title="Error from simulation / wallet / on-chain revert"
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
