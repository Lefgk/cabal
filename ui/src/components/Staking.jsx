import { useState } from 'react';
import { useAccount, useReadContract, useWriteContract } from 'wagmi';
import { formatEther, parseEther, maxUint256 } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { STAKING_VAULT_ABI, ERC20_ABI } from '../config/abis.js';

const vaultAddr = ADDRESSES.stakingVault;
const tokenAddr = ADDRESSES.stakeToken;

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

  const { writeContract, isPending: isWriting } = useWriteContract();

  // Reads
  const { data: totalStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalStaked',
  });
  const { data: userStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'stakedBalance',
    args: [address],
  });
  const { data: earnedRaw } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'earned',
    args: [address],
  });
  const { data: rewardRate } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'rewardRate',
  });
  const { data: periodFinish } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'periodFinish',
  });
  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address],
  });
  const { data: allowance } = useReadContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'allowance',
    args: [address, vaultAddr],
  });
  const { data: tokenBalance } = useReadContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [address],
  });

  const now = Math.floor(Date.now() / 1000);
  const timeLeft = periodFinish ? Number(periodFinish) - now : 0;

  const needsApproval = (() => {
    if (!stakeAmount || !allowance) return true;
    try {
      return parseEther(stakeAmount) > allowance;
    } catch {
      return true;
    }
  })();

  const handleApprove = () => {
    writeContract({
      address: tokenAddr, abi: ERC20_ABI, functionName: 'approve',
      args: [vaultAddr, maxUint256],
    });
  };

  const handleStake = () => {
    if (!stakeAmount) return;
    writeContract({
      address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'stake',
      args: [parseEther(stakeAmount)],
    });
    setStakeAmount('');
  };

  const handleWithdraw = () => {
    if (!withdrawAmount) return;
    writeContract({
      address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'withdraw',
      args: [parseEther(withdrawAmount)],
    });
    setWithdrawAmount('');
  };

  const handleClaim = () => {
    writeContract({
      address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'getReward',
    });
  };

  const handleExit = () => {
    writeContract({
      address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'exit',
    });
  };

  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };

  return (
    <div className="card">
      <div className="section-header">
        <h2>Staking</h2>
        {isTop && <span className="top-staker-badge">Top Staker</span>}
      </div>

      <div className="stat-row">
        <span className="stat-label">Total Staked</span>
        <span className="stat-value">{fmt(totalStaked)}</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Your Stake</span>
        <span className="stat-value">{fmt(userStaked)}</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Earned Rewards</span>
        <span className="stat-value">{fmt(earnedRaw)}</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Reward Rate</span>
        <span className="stat-value">{fmt(rewardRate)} / sec</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Period Ends</span>
        <span className="stat-value">{formatCountdown(timeLeft)}</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Wallet Balance</span>
        <span className="stat-value">{fmt(tokenBalance)}</span>
      </div>

      {/* Stake */}
      <div className="input-group">
        <input
          type="text"
          placeholder="Amount to stake"
          value={stakeAmount}
          onChange={(e) => setStakeAmount(e.target.value)}
        />
        {needsApproval ? (
          <button onClick={handleApprove} disabled={isWriting}>
            Approve
          </button>
        ) : (
          <button onClick={handleStake} disabled={isWriting || !stakeAmount}>
            Stake
          </button>
        )}
      </div>

      {/* Withdraw */}
      <div className="input-group">
        <input
          type="text"
          placeholder="Amount to withdraw"
          value={withdrawAmount}
          onChange={(e) => setWithdrawAmount(e.target.value)}
        />
        <button onClick={handleWithdraw} disabled={isWriting || !withdrawAmount}>
          Withdraw
        </button>
      </div>

      {/* Claim & Exit */}
      <div className="input-group">
        <button className="btn-green" onClick={handleClaim} disabled={isWriting}>
          Claim Rewards
        </button>
        <button className="btn-red" onClick={handleExit} disabled={isWriting}>
          Exit (Withdraw All + Claim)
        </button>
      </div>
    </div>
  );
}
