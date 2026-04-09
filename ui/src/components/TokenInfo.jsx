import { useState } from 'react';
import { useAccount, useWriteContract } from 'wagmi';
import { useReadContract, useReadContracts } from '../hooks/usePls.js';
import { formatEther, parseEther, isAddress } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TOKEN_TAX_ABI, STAKING_VAULT_ABI, TREASURY_DAO_ABI, ERC20_ABI } from '../config/abis.js';
import TokenIcon from './TokenIcon.jsx';

const TAX_TYPE_LABELS = {
  0: 'Burn',
  1: 'External Burn',
  2: 'Dev / Treasury',
  3: 'Reflection',
  4: 'Yield',
  5: 'Auto LP',
};

const TAX_MOMENT_LABELS = {
  0: 'Both',
  1: 'Buy Only',
  2: 'Sell Only',
  3: 'Buy Only',
  4: 'Sell Only',
};

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const DEAD_ADDRESS = '0x000000000000000000000000000000000000dEaD';

// Map tax-receiver addr → human label describing the downstream behaviour.
// Keyed by lowercase address so we're robust to checksum variation.
function taxFlowLabel(receiver) {
  if (!receiver) return null;
  const r = receiver.toLowerCase();
  if (r === ADDRESSES.stakingVault.toLowerCase()) return '→ pHEX (stakers)';
  if (r === ADDRESSES.treasuryDAO.toLowerCase())  return '→ WPLS (DAO)';
  return null;
}

const OTTERSCAN = 'https://otter.pulsechain.com/address/';

const TAX_COUNT = 5; // hardcoded — no taxCount() on-chain

function formatNumber(value) {
  if (!value) return '0';
  const num = Number(formatEther(value));
  return num.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export default function TokenInfo() {
  const tokenAddress = ADDRESSES.stakeToken;
  const tokenContract = { address: tokenAddress, abi: TOKEN_TAX_ABI };

  const { address: account } = useAccount();
  const { writeContract, isPending: isTransferring } = useWriteContract();
  const [transferTo, setTransferTo] = useState('');
  const [transferAmount, setTransferAmount] = useState('');

  const { data: walletBalance } = useReadContract({
    address: tokenAddress,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: [account],
    query: { enabled: !!account },
  });

  const validTo = transferTo && isAddress(transferTo);
  let parsedAmount = null;
  try {
    if (transferAmount) parsedAmount = parseEther(transferAmount);
  } catch {
    parsedAmount = null;
  }
  const canTransfer =
    !!account &&
    !isTransferring &&
    validTo &&
    parsedAmount !== null &&
    parsedAmount > 0n;

  const handleTransfer = () => {
    if (!canTransfer) return;
    writeContract({
      address: tokenAddress,
      abi: ERC20_ABI,
      functionName: 'transfer',
      args: [transferTo, parsedAmount],
    });
    setTransferAmount('');
  };

  // Read basic token details
  const { data: tokenName } = useReadContract({ ...tokenContract, functionName: 'name' });
  const { data: tokenSymbol } = useReadContract({ ...tokenContract, functionName: 'symbol' });
  const { data: totalSupply } = useReadContract({ ...tokenContract, functionName: 'totalSupply' });
  const { data: tradingEnabled } = useReadContract({ ...tokenContract, functionName: 'tradingEnabled' });
  const { data: tokenOwner } = useReadContract({ ...tokenContract, functionName: 'owner' });

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

  // Read all 5 taxes
  const taxCalls = Array.from({ length: TAX_COUNT }, (_, i) => ({
    ...tokenContract,
    functionName: 'taxes',
    args: [BigInt(i)],
  }));
  const { data: taxResults } = useReadContracts({ contracts: taxCalls });

  const sym = tokenSymbol || '???';

  return (
    <div className="card">
      <h2><TokenIcon symbol={sym} size={24} />{tokenName || 'Token'} ({sym})</h2>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Total Supply</span>
          <span className="stat-value">{formatNumber(totalSupply)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Trading</span>
          <span className="stat-value">
            {tradingEnabled === undefined
              ? '…'
              : tradingEnabled
                ? <span className="badge badge-active">Enabled</span>
                : <span className="badge badge-defeated">Disabled</span>}
          </span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Vault</span>
          <span className="stat-value">
            {vaultPaused === undefined
              ? '…'
              : vaultPaused
                ? <span className="badge badge-defeated">Paused</span>
                : <span className="badge badge-active">Active</span>}
          </span>
        </div>
      </div>

      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Tax Structure (5% total)</h3>
      <div className="address-grid">
        {taxResults && taxResults.length > 0 ? (
          taxResults.map((res, i) => {
            if (!res || res.status === 'failure') return null;
            const r = res.result;
            // Struct: (taxMoment, taxType, field2, bps, wallet, token, burnAddress, rewardInPls, field8)
            const taxMoment = Number(r[0]);
            const taxType = Number(r[1]);
            const bps = Number(r[3]);
            const wallet = r[4];
            const taxToken = r[5];
            const rewardInPls = r[7];
            const pct = (bps / 100).toFixed(2);
            const label = TAX_TYPE_LABELS[taxType] || `Type ${taxType}`;
            const momentLabel = TAX_MOMENT_LABELS[taxMoment] || '';
            const hasToken = taxToken && taxToken !== ZERO_ADDRESS && taxToken !== DEAD_ADDRESS;

            return (
              <div className="address-row" key={i} style={{ flexWrap: 'wrap', gap: 6 }}>
                <span className="stat-label" style={{ minWidth: 140 }}>
                  {label} ({pct}%)
                  {momentLabel && momentLabel !== 'Both' && (
                    <span className="badge badge-pending" style={{ marginLeft: 6, fontSize: 10 }}>{momentLabel}</span>
                  )}
                </span>
                <span className="stat-value" style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
                  {hasToken && (
                    <a className="address-link" href={`${OTTERSCAN}${taxToken}`} target="_blank" rel="noopener noreferrer">
                      {taxToken}
                    </a>
                  )}
                  {taxType === 2 && rewardInPls && (() => {
                    const flow = taxFlowLabel(wallet);
                    return (
                      <span className="badge badge-active">
                        {flow ? `PLS ${flow}` : 'Paid in PLS'}
                      </span>
                    );
                  })()}
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

      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Lifetime Totals</h3>
      <div className="stats-grid">
        <div className="stat-box">
          <span className="stat-label">Burned</span>
          <span className="stat-value highlight-green">{formatNumber(totalBurned)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Yield</span>
          <span className="stat-value highlight-green">{formatNumber(totalYield)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Liquified</span>
          <span className="stat-value highlight-green">{formatNumber(totalLiquify)}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Dev</span>
          <span className="stat-value highlight-green">{formatNumber(totalSupport)}</span>
        </div>
      </div>

      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Transfer</h3>
      <p className="help-text" style={{ marginTop: 0 }}>
        Send {sym} to any address. Note: 5% tax applies on transfer.
        {account && (
          <>
            {' '}Wallet: {walletBalance !== undefined ? formatNumber(walletBalance) : '…'} {sym}
          </>
        )}
      </p>
      <div className="input-group">
        <input
          type="text"
          placeholder="Recipient address (0x…)"
          value={transferTo}
          onChange={(e) => setTransferTo(e.target.value)}
          disabled={!account}
        />
      </div>
      <div className="input-group">
        <input
          type="text"
          placeholder={`Amount of ${sym}`}
          value={transferAmount}
          onChange={(e) => setTransferAmount(e.target.value)}
          disabled={!account}
        />
        <button onClick={handleTransfer} disabled={!canTransfer}>
          {isTransferring ? 'Sending…' : 'Transfer'}
        </button>
      </div>
      {transferTo && !validTo && (
        <p className="help-text" style={{ color: 'var(--danger, #c33)' }}>Invalid address</p>
      )}
      {!account && (
        <p className="help-text">Connect wallet to transfer.</p>
      )}

      <h3 style={{ marginTop: 20, marginBottom: 4 }}>Owners</h3>
      <div className="address-grid">
        <div className="address-row">
          <span className="stat-label">Token</span>
          {tokenOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${tokenOwner}`} target="_blank" rel="noopener noreferrer">{tokenOwner}</a>
          ) : <span className="stat-value">…</span>}
        </div>
        <div className="address-row">
          <span className="stat-label">Vault</span>
          {vaultOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${vaultOwner}`} target="_blank" rel="noopener noreferrer">{vaultOwner}</a>
          ) : <span className="stat-value">…</span>}
        </div>
        <div className="address-row">
          <span className="stat-label">DAO</span>
          {daoOwner ? (
            <a className="address-link" href={`${OTTERSCAN}${daoOwner}`} target="_blank" rel="noopener noreferrer">{daoOwner}</a>
          ) : <span className="stat-value">…</span>}
        </div>
      </div>
    </div>
  );
}
