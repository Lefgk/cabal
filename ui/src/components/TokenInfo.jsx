import { useReadContract, useReadContracts } from 'wagmi';
import { formatEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TOKEN_TAX_ABI, STAKING_VAULT_ABI, TREASURY_DAO_ABI } from '../config/abis.js';

const TAX_TYPE_LABELS = {
  0: 'Burn',
  1: 'External Burn',
  2: 'Dev / Treasury',
  3: 'Reflection',
  4: 'Yield',
  5: 'Auto LP',
};

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

const OTTERSCAN = 'https://otter.pulsechain.com/address/';

function formatNumber(value) {
  if (!value) return '0';
  const num = Number(formatEther(value));
  return num.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export default function TokenInfo() {
  const tokenAddress = ADDRESSES.stakeToken;
  const tokenContract = { address: tokenAddress, abi: TOKEN_TAX_ABI };

  // Read basic token details
  const { data: tokenName } = useReadContract({ ...tokenContract, functionName: 'name' });
  const { data: tokenSymbol } = useReadContract({ ...tokenContract, functionName: 'symbol' });
  const { data: totalSupply } = useReadContract({ ...tokenContract, functionName: 'totalSupply' });
  const { data: tradingEnabled } = useReadContract({ ...tokenContract, functionName: 'tradingEnabled' });
  const { data: tokenOwner } = useReadContract({ ...tokenContract, functionName: 'owner' });
  const { data: taxCount } = useReadContract({ ...tokenContract, functionName: 'taxCount' });

  // Lifetime stats
  const { data: totalBurned } = useReadContract({ ...tokenContract, functionName: 'totalBurned' });
  const { data: totalYield } = useReadContract({ ...tokenContract, functionName: 'totalYield' });
  const { data: totalLiquify } = useReadContract({ ...tokenContract, functionName: 'totalLiquify' });
  const { data: totalSupport } = useReadContract({ ...tokenContract, functionName: 'totalSupport' });

  // Vault owner + paused
  const { data: vaultOwner } = useReadContract({
    address: ADDRESSES.stakingVault,
    abi: STAKING_VAULT_ABI,
    functionName: 'owner',
  });
  const { data: vaultPaused } = useReadContract({
    address: ADDRESSES.stakingVault,
    abi: STAKING_VAULT_ABI,
    functionName: 'paused',
  });

  // DAO owner
  const { data: daoOwner } = useReadContract({
    address: ADDRESSES.treasuryDAO,
    abi: TREASURY_DAO_ABI,
    functionName: 'owner',
  });

  // Read all taxes
  const taxCountNum = taxCount ? Number(taxCount) : 0;
  const taxCalls = Array.from({ length: taxCountNum }, (_, i) => ({
    ...tokenContract,
    functionName: 'taxes',
    args: [BigInt(i)],
  }));
  const { data: taxResults } = useReadContracts({ contracts: taxCalls });

  const sym = tokenSymbol || '???';

  return (
    <div className="card">
      <h2>Token Info</h2>
      <p className="help-text">
        On-chain details about the token, its tax structure, and lifetime statistics. All data is read directly from the smart contracts on PulseChain.
      </p>

      {/* Token Details */}
      <h3>Token Details</h3>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Name</span>
          <span className="stat-value">{tokenName || '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Symbol</span>
          <span className="stat-value">{sym}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Supply</span>
          <span className="stat-value">{formatNumber(totalSupply)} {sym}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Trading Enabled</span>
          <span className="stat-value">
            {tradingEnabled === undefined
              ? '...'
              : tradingEnabled
                ? <span className="badge badge-active">Yes</span>
                : <span className="badge badge-defeated">No</span>}
          </span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Owner</span>
          <span className="stat-value">
            {tokenOwner ? (
              <a className="address-link" href={`${OTTERSCAN}${tokenOwner}`} target="_blank" rel="noopener noreferrer">
                {tokenOwner}
              </a>
            ) : '...'}
          </span>
        </div>
      </div>

      {/* Tax Structure */}
      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Tax Structure (5% total)</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>Every buy and sell on PulseX is taxed 5% total, split across these categories. Yield goes to stakers as eHEX rewards, Dev/Treasury fills the DAO treasury, Auto LP adds liquidity, External Burn buys and burns ZKP, and Burn destroys tokens permanently.</p>
      <div className="address-grid">
        {taxResults && taxResults.length > 0 ? (
          taxResults.map((res, i) => {
            if (!res || res.status === 'failure') return null;
            const result = res.result;
            const taxType = Number(result[0]);
            const bps = Number(result[1]);
            const taxToken = result[2];
            const rewardInPls = result[3];
            const pct = (bps / 100).toFixed(2);
            const label = TAX_TYPE_LABELS[taxType] || `Type ${taxType}`;
            const hasToken = taxToken && taxToken !== ZERO_ADDRESS;

            return (
              <div className="address-row" key={i}>
                <span className="stat-label">{label} ({pct}%)</span>
                <span className="stat-value" style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
                  {hasToken && (
                    <a className="address-link" href={`${OTTERSCAN}${taxToken}`} target="_blank" rel="noopener noreferrer">
                      {taxToken}
                    </a>
                  )}
                  {taxType === 2 && rewardInPls && (
                    <span className="badge badge-active">Rewards in PLS</span>
                  )}
                </span>
              </div>
            );
          })
        ) : (
          <div className="address-row">
            <span className="stat-label">Loading taxes...</span>
          </div>
        )}
      </div>

      {/* Lifetime Stats */}
      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Lifetime Stats</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>Cumulative totals since token launch. These numbers represent the total amount of tokens processed by each tax type.</p>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Total Burned</span>
          <span className="stat-value highlight-green">{formatNumber(totalBurned)} {sym}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Yield Distributed</span>
          <span className="stat-value highlight-green">{formatNumber(totalYield)} {sym}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Liquified</span>
          <span className="stat-value highlight-green">{formatNumber(totalLiquify)} {sym}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Total Dev / Support</span>
          <span className="stat-value highlight-green">{formatNumber(totalSupport)} {sym}</span>
        </div>
      </div>

      {/* Contract Ownership */}
      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Contract Ownership</h3>
      <p className="help-text" style={{ marginBottom: 10 }}>The owner can adjust parameters like voting period, quorum, and pause the vault in emergencies. Ownership can be transferred or renounced.</p>
      <div className="address-grid">
        <div className="address-row">
          <span className="stat-label">Token Owner</span>
          {tokenOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${tokenOwner}`} target="_blank" rel="noopener noreferrer">
              {tokenOwner}
            </a>
          ) : <span className="stat-value">...</span>}
        </div>
        <div className="address-row">
          <span className="stat-label">Vault Owner</span>
          {vaultOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${vaultOwner}`} target="_blank" rel="noopener noreferrer">
              {vaultOwner}
            </a>
          ) : <span className="stat-value">...</span>}
        </div>
        <div className="address-row">
          <span className="stat-label">DAO Owner</span>
          {daoOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${daoOwner}`} target="_blank" rel="noopener noreferrer">
              {daoOwner}
            </a>
          ) : <span className="stat-value">...</span>}
        </div>
        <div className="address-row">
          <span className="stat-label">Vault Paused</span>
          <span className="stat-value">
            {vaultPaused === undefined
              ? '...'
              : vaultPaused
                ? <span className="badge badge-defeated">Paused</span>
                : <span className="badge badge-active">Active</span>}
          </span>
        </div>
      </div>
    </div>
  );
}
