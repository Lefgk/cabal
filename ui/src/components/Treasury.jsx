import { useReadContract } from 'wagmi';
import { formatEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, ERC20_ABI } from '../config/abis.js';

const daoAddr = ADDRESSES.treasuryDAO;

export default function Treasury() {
  const { data: availableBalance } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'availableBalance',
  });

  // Read WPLS balance of the DAO contract to derive locked amount
  // stakeToken is WPLS in this context
  const { data: totalWplsBalance } = useReadContract({
    address: ADDRESSES.stakeToken, abi: ERC20_ABI, functionName: 'balanceOf',
    args: [daoAddr],
  });

  const fmt = (val) => {
    if (val === undefined || val === null) return '...';
    return Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });
  };

  const locked = (totalWplsBalance !== undefined && totalWplsBalance !== null &&
    availableBalance !== undefined && availableBalance !== null)
    ? totalWplsBalance - availableBalance
    : undefined;

  return (
    <div className="card">
      <h2>Treasury</h2>

      <div className="stat-row">
        <span className="stat-label">Available Balance</span>
        <span className="stat-value">{fmt(availableBalance)} WPLS</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Locked (in proposals)</span>
        <span className="stat-value">{fmt(locked)} WPLS</span>
      </div>
      <div className="stat-row">
        <span className="stat-label">Total WPLS Held</span>
        <span className="stat-value">{fmt(totalWplsBalance)} WPLS</span>
      </div>
    </div>
  );
}
