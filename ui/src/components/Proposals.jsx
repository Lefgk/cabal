import { useState, useEffect, useCallback } from 'react';
import { useAccount, useSignMessage, usePublicClient } from 'wagmi';
import { useReadContract, useReadContracts, useSafeWriteContract, prettyError } from '../hooks/usePls.js';
import { useSimulateContract } from 'wagmi';
import { formatEther, parseEther, isAddress } from 'viem';
import { ADDRESSES, DAO_DEPLOY_BLOCK } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI } from '../config/abis.js';
import { PULSECHAIN_ID } from '../config/wagmi.js';
import TokenIcon from './TokenIcon.jsx';

const API_BASE = import.meta.env.VITE_API_URL || 'https://cabal-comments-production.up.railway.app';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;

// ProposalState enum: Pending=0, Active=1, Defeated=2, Succeeded=3, Executed=4, Expired=5
const STATE_LABELS = ['Pending', 'Active', 'Defeated', 'Succeeded', 'Executed', 'Expired'];
const STATE_CLASSES = ['badge-pending', 'badge-active', 'badge-defeated', 'badge-succeeded', 'badge-executed', 'badge-pending'];

// ActionType enum: SendPLS=0, BuyAndBurn=1, AddAndBurnLP=2, Custom=3
const ACTION_LABELS = ['Send PLS', 'Buy & Burn', 'Add & Burn LP', 'Custom'];

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

// Tokens hard-coded from the constructor (no events emitted for these).
// Symbol map used as display labels in dropdowns.
const CONSTRUCTOR_TOKENS = {
  '0x90F055196778e541018482213Ca50648cEA1a050': 'ZKP',
  '0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07': 'USDC',
  '0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f': 'USDT',
  '0xefD766cCb38EaF1dfd701853BFCe31359239F305': 'DAI',
  '0x6B175474E89094C44Da98b954EedeAC495271d0F': 'pDAI',
  '0xF6f8Db0aBa00007681F8fAF16A0FDa1c9B030b11': 'PRVX',
  '0xA1077a294dDE1B09bB078844df40758a5D0f9a27': 'WPLS',
  '0x95B303987A60C71504D99Aa1b13B4DA07b0790ab': 'PLSX',
};

const TOKEN_WHITELISTED_EVENT = {
  name: 'TokenWhitelisted',
  type: 'event',
  inputs: [{ name: 'token', type: 'address', indexed: true }],
};
const TOKEN_REMOVED_EVENT = {
  name: 'TokenRemovedFromWhitelist',
  type: 'event',
  inputs: [{ name: 'token', type: 'address', indexed: true }],
};

function useWhitelistedTokens() {
  const publicClient = usePublicClient({ chainId: PULSECHAIN_ID });
  const [tokens, setTokens] = useState(
    Object.entries(CONSTRUCTOR_TOKENS).map(([address, symbol]) => ({ address, symbol }))
  );

  useEffect(() => {
    if (!publicClient) return;
    let cancelled = false;

    async function load() {
      try {
        const [added, removed] = await Promise.all([
          publicClient.getLogs({
            address: daoAddr,
            event: TOKEN_WHITELISTED_EVENT,
            fromBlock: DAO_DEPLOY_BLOCK,
            toBlock: 'latest',
          }),
          publicClient.getLogs({
            address: daoAddr,
            event: TOKEN_REMOVED_EVENT,
            fromBlock: DAO_DEPLOY_BLOCK,
            toBlock: 'latest',
          }),
        ]);

        const removedSet = new Set(removed.map(e => e.args.token.toLowerCase()));
        const knownSet = new Set(Object.keys(CONSTRUCTOR_TOKENS).map(a => a.toLowerCase()));

        const result = Object.entries(CONSTRUCTOR_TOKENS)
          .filter(([addr]) => !removedSet.has(addr.toLowerCase()))
          .map(([address, symbol]) => ({ address, symbol }));

        for (const log of added) {
          const addr = log.args.token;
          if (!knownSet.has(addr.toLowerCase()) && !removedSet.has(addr.toLowerCase())) {
            result.push({ address: addr, symbol: `${addr.slice(0, 6)}…` });
          }
        }

        if (!cancelled) setTokens(result);
      } catch (e) {
        console.error('Failed to load whitelisted tokens', e);
      }
    }

    load();
  }, [publicClient]);

  return tokens;
}

const fmtTok = (val) => Number(formatEther(val || 0n)).toLocaleString(undefined, { maximumFractionDigits: 2 });
const fmtDate = (unix) => new Date(Number(unix) * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const fmtCountdown = (seconds) => {
  if (seconds <= 0) return 'Ended';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
};
const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

const relativeTime = (timestamp) => {
  const now = Date.now();
  const diff = Math.max(0, Math.floor((now - new Date(timestamp).getTime()) / 1000));
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
};

export default function Proposals() {
  const { address } = useAccount();
  const {
    writeContract,
    isPending: isWriting,
    isMining,
    isOnWrongChain,
    txError,
  } = useSafeWriteContract();
  const busy = isWriting || isMining;

  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address], query: { enabled: !!address },
  });
  const { data: proposalCount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'proposalCount',
  });
  const { data: supermajorityPct } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'supermajorityPct',
  });
  const { data: minVoters } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'minVoters',
  });
  const { data: availableBalance } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'availableBalance',
  });
  const { data: lockedAmount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'lockedAmount',
  });
  const { data: votingPeriod } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'votingPeriod',
  });

  const count = proposalCount ? Number(proposalCount) : 0;

  // Proposal IDs start at 1
  const proposalCalls = [];
  for (let i = 1; i <= count; i++) {
    proposalCalls.push({
      address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'proposals', args: [BigInt(i)],
    });
    proposalCalls.push({
      address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'state', args: [BigInt(i)],
    });
  }

  const { data: proposalResults } = useReadContracts({
    contracts: proposalCalls,
    query: { enabled: count > 0 },
  });

  const proposals = [];
  if (proposalResults) {
    for (let i = 0; i < proposalResults.length; i += 2) {
      const pResult = proposalResults[i];
      const sResult = proposalResults[i + 1];
      if (pResult?.status === 'success' && sResult?.status === 'success') {
        proposals.push({
          ...pResult.result,
          state: Number(sResult.result),
        });
      }
    }
  }

  const fmtVotingPeriod = (secs) => {
    if (!secs) return '...';
    const s = Number(secs);
    if (s < 3600) return `${s / 60}m`;
    if (s < 86400) return `${s / 3600}h`;
    return `${s / 86400}d`;
  };

  return (
    <div className="card">
      <h2>Proposals ({count})</h2>
      <p className="help-text">
        Top stakers propose, all stakers vote (weight = stake). Needs {supermajorityPct ? `${supermajorityPct}%` : '...'} supermajority + {minVoters ? `${minVoters}` : '...'} unique voters to pass.
      </p>

      <div className="stats-grid" style={{ marginBottom: 16 }}>
        <div className="stat-box" title="PLS available for new proposals (total minus locked by active proposals)">
          <span className="stat-label">Treasury Available</span>
          <span className="stat-value">{availableBalance !== undefined ? fmtTok(availableBalance) : '...'} PLS</span>
        </div>
        <div className="stat-box" title="PLS locked by active/pending proposals — released when proposals execute or expire">
          <span className="stat-label">Locked</span>
          <span className="stat-value">{lockedAmount !== undefined ? fmtTok(lockedAmount) : '...'} PLS</span>
        </div>
        <div className="stat-box" title="Total PLS in the DAO treasury">
          <span className="stat-label">Total Treasury</span>
          <span className="stat-value">
            {availableBalance !== undefined && lockedAmount !== undefined
              ? fmtTok(availableBalance + lockedAmount)
              : '...'} PLS
          </span>
        </div>
      </div>

      <div className="stats-grid" style={{ marginBottom: 16 }}>
        <div className="stat-box">
          <span className="stat-label">Supermajority</span>
          <span className="stat-value">{supermajorityPct !== undefined ? `${supermajorityPct}%` : '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Min Voters</span>
          <span className="stat-value">{minVoters !== undefined ? `${minVoters}` : '...'}</span>
        </div>
        <div className="stat-box">
          <span className="stat-label">Vote Duration</span>
          <span className="stat-value">{fmtVotingPeriod(votingPeriod)}</span>
        </div>
      </div>

      {count === 0 && <p style={{ color: 'var(--text)' }}>No proposals yet.</p>}

      {[...proposals].reverse().map((p) => (
        <ProposalCard
          key={Number(p.id)}
          proposal={p}
          address={address}
          busy={busy}
          isOnWrongChain={isOnWrongChain}
          writeContract={writeContract}
          supermajorityPct={supermajorityPct}
          minVoters={minVoters}
        />
      ))}

      <CreateProposalForm
        writeContract={writeContract}
        busy={busy}
        isOnWrongChain={isOnWrongChain}
        address={address}
        isTop={isTop}
        availableBalance={availableBalance}
      />
      {address && isOnWrongChain && (
        <p className="help-text" style={{ marginTop: 8, color: 'var(--danger, #c33)' }}>
          Switch your wallet to PulseChain (369) to vote or propose.
        </p>
      )}
      {isMining && (
        <p className="help-text" style={{ marginTop: 8 }}>Waiting for confirmation…</p>
      )}
      {txError && (
        <div
          style={{
            marginTop: 12,
            padding: '10px 14px',
            background: 'rgba(239,68,68,0.12)',
            border: '1px solid rgba(239,68,68,0.45)',
            borderRadius: 8,
            color: '#fecaca',
            fontSize: 13,
            wordBreak: 'break-word',
          }}
        >
          <strong>Transaction failed:</strong> {prettyError(txError)}
        </div>
      )}
    </div>
  );
}

function ProposalCard({ proposal, address, busy, isOnWrongChain, writeContract, supermajorityPct, minVoters }) {
  const p = proposal;
  const [expanded, setExpanded] = useState(false);

  const stateLabel = STATE_LABELS[p.state] ?? 'Unknown';
  const stateClass = STATE_CLASSES[p.state] ?? 'badge-pending';
  const actionLabel = ACTION_LABELS[p.actionType] ?? 'Unknown';

  const totalVotes = p.yesVotes + p.noVotes;
  const yesPct = totalVotes > 0n ? Number((p.yesVotes * 10000n) / totalVotes) / 100 : 0;
  const noPct = totalVotes > 0n ? 100 - yesPct : 0;

  const now = Math.floor(Date.now() / 1000);
  const timeLeft = Number(p.endTime) - now;
  const isActive = p.state === 1;
  const isSucceeded = p.state === 3;

  const threshold = supermajorityPct ? Number(supermajorityPct) : 65;
  const voterThreshold = minVoters ? Number(minVoters) : 5;
  const passesMajority = yesPct >= threshold;
  const passesVoters = Number(p.voters) >= voterThreshold;

  const { data: receipt } = useReadContract({
    address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'getReceipt',
    args: [p.id, address],
    query: { enabled: !!address },
  });
  const hasVoted = receipt?.hasVoted;

  const handleVote = (support) => {
    writeContract({
      address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'castVote',
      args: [p.id, support],
    });
  };
  const handleExecute = () => {
    writeContract({
      address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'executeProposal',
      args: [p.id],
    });
  };

  const tokenAddr = p.actionToken && p.actionToken !== ZERO_ADDR ? p.actionToken : null;
  const tokenSymbol = tokenAddr ? (CONSTRUCTOR_TOKENS[tokenAddr] ?? shortAddr(tokenAddr)) : null;

  return (
    <div className="proposal-card" onClick={() => setExpanded(!expanded)} style={{ cursor: 'pointer' }}>
      <div className="proposal-header">
        <h3 style={{ margin: 0 }}>#{Number(p.id)} — {p.description}</h3>
        <span className={`badge ${stateClass}`}>{stateLabel}</span>
      </div>

      <div className="proposal-meta">
        <span>
          <strong>{actionLabel}</strong>
          {p.amount > 0n && <> · <strong>{fmtTok(p.amount)} PLS</strong></>}
          {tokenSymbol && <> · <TokenIcon symbol={tokenSymbol} />{tokenSymbol}</>}
        </span>
        <span>{isActive ? `Ends in ${fmtCountdown(timeLeft)}` : `Ended ${fmtDate(p.endTime)}`}</span>
      </div>

      <div className="proposal-meta" style={{ marginTop: 8 }}>
        <span style={{ color: 'var(--green)' }}>Yes: {fmtTok(p.yesVotes)} ({yesPct.toFixed(1)}%)</span>
        <span style={{ color: 'var(--red)' }}>No: {fmtTok(p.noVotes)} ({noPct.toFixed(1)}%)</span>
      </div>
      {totalVotes > 0n && (
        <div className="vote-bar">
          <div className="vote-bar-yes" style={{ width: `${yesPct}%` }} />
          <div className="vote-bar-no" style={{ width: `${noPct}%` }} />
        </div>
      )}

      <div style={{ marginTop: 6, fontSize: 12, color: 'var(--text)' }}>
        Voters: {Number(p.voters)} / {voterThreshold} {passesVoters ? '✓' : ''}
        {' · '}
        Majority: {yesPct.toFixed(0)}% / {threshold}% {passesMajority ? '✓' : ''}
      </div>

      {expanded && (
        <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid var(--border)', fontSize: 12, color: 'var(--text)' }}>
          <div><strong>Proposer:</strong> <a href={`https://otter.pulsechain.com/address/${p.proposer}`} target="_blank" rel="noopener noreferrer" className="address-link" onClick={(e) => e.stopPropagation()}>{p.proposer}</a></div>
          <div><strong>Created:</strong> {fmtDate(p.startTime)}</div>
          {tokenAddr && <div><strong>Token:</strong> <a href={`https://otter.pulsechain.com/address/${tokenAddr}`} target="_blank" rel="noopener noreferrer" className="address-link" onClick={(e) => e.stopPropagation()}>{tokenAddr}</a></div>}
          {p.target && p.target !== ZERO_ADDR && <div><strong>Target:</strong> <a href={`https://otter.pulsechain.com/address/${p.target}`} target="_blank" rel="noopener noreferrer" className="address-link" onClick={(e) => e.stopPropagation()}>{p.target}</a></div>}
          <div><strong>Executed:</strong> {p.executed ? 'Yes' : 'No'}</div>

          <div onClick={(e) => e.stopPropagation()}>
            <CommentsSection proposalId={Number(p.id)} expanded={expanded} />
          </div>
        </div>
      )}

      {isActive && !hasVoted && (
        <div className="vote-buttons" onClick={(e) => e.stopPropagation()}>
          <button className="btn-green" onClick={() => handleVote(true)} disabled={!address || busy || isOnWrongChain}>Vote Yes</button>
          <button className="btn-red" onClick={() => handleVote(false)} disabled={!address || busy || isOnWrongChain}>Vote No</button>
        </div>
      )}
      {isActive && hasVoted && (
        <p style={{ fontSize: 13, color: 'var(--text)', marginTop: 8 }}>
          You voted <strong>{receipt?.support ? 'Yes' : 'No'}</strong> with {fmtTok(receipt?.weight || 0n)} weight
        </p>
      )}
      {isSucceeded && (
        <div style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
          <button className="btn-blue" onClick={handleExecute} disabled={!address || busy || isOnWrongChain}>Execute Proposal</button>
        </div>
      )}

      <div style={{ marginTop: 8, fontSize: 11, color: 'var(--text-dim, #888)', textAlign: 'right' }}>
        {expanded ? '▲ Click to collapse' : '▼ Click for details'}
      </div>
    </div>
  );
}

function CreateProposalForm({ writeContract, busy, isOnWrongChain, address, isTop, availableBalance }) {
  const whitelistedTokens = useWhitelistedTokens();

  const [actionType, setActionType] = useState(0); // 0=SendPLS,1=BuyAndBurn,2=AddAndBurnLP,3=Custom
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');
  const [actionToken, setActionToken] = useState('');
  const [secondToken, setSecondToken] = useState(''); // AddAndBurnLP token/token pair
  const [customTarget, setCustomTarget] = useState('');
  const [customData, setCustomData] = useState('');

  let amountWei = null;
  try { if (amount) amountWei = parseEther(amount); } catch { /* invalid */ }

  const exceedsTreasury =
    amountWei !== null && availableBalance !== undefined && amountWei > availableBalance;

  // Build propose() args from current form state
  const buildArgs = () => {
    const amt = amountWei ?? 0n;
    const desc = description;
    const aType = actionType;

    if (aType === 0) {
      // SendPLS: target ignored by contract (set to marketingWallet)
      return [amt, ZERO_ADDR, desc, 0, ZERO_ADDR, '0x'];
    }
    if (aType === 1) {
      // BuyAndBurn
      return [amt, ZERO_ADDR, desc, 1, actionToken || ZERO_ADDR, '0x'];
    }
    if (aType === 2) {
      // AddAndBurnLP: secondToken=address(0) means token/PLS pair
      return [amt, secondToken || ZERO_ADDR, desc, 2, actionToken || ZERO_ADDR, '0x'];
    }
    // Custom
    return [amt, customTarget || ZERO_ADDR, desc, 3, ZERO_ADDR, customData || '0x'];
  };

  const tokensForBurn = whitelistedTokens.filter(
    t => t.address.toLowerCase() !== '0xa1077a294dde1b09bb078844df40758a5d0f9a27' // exclude WPLS for BuyAndBurn
  );

  const inputsComplete = (() => {
    if (!amountWei || amountWei <= 0n || !description) return false;
    if (actionType === 1) return !!actionToken;
    if (actionType === 2) return !!actionToken;
    if (actionType === 3) return isAddress(customTarget) && !!customData;
    return true; // SendPLS
  })();

  const args = inputsComplete && !exceedsTreasury ? buildArgs() : undefined;

  const { error: simError, isFetching: isSimulating } = useSimulateContract({
    address: ADDRESSES.treasuryDAO,
    abi: TREASURY_DAO_ABI,
    functionName: 'propose',
    args,
    account: address,
    chainId: PULSECHAIN_ID,
    query: {
      enabled: !!address && !!isTop && !!args && !isOnWrongChain,
      refetchOnWindowFocus: false,
      retry: false,
    },
  });

  const handleCreate = () => {
    if (!args) return;
    writeContract({
      address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'propose',
      args,
    });
  };

  const gateMsg = !address
    ? 'Connect wallet to propose.'
    : !isTop
      ? 'Only top-100 stakers can create proposals. Stake more to qualify.'
      : null;

  let warning = null;
  if (exceedsTreasury) {
    warning = `Amount exceeds available treasury (${fmtTok(availableBalance)} PLS).`;
  } else if (simError && inputsComplete) {
    warning = `Simulation failed: ${prettyError(simError)}`;
  }

  return (
    <div style={{ marginTop: 24, paddingTop: 20, borderTop: '1px solid var(--border)' }}>
      <h3>Create Proposal</h3>
      {gateMsg && <p className="help-text" style={{ marginBottom: 12 }}>{gateMsg}</p>}

      {/* Action type */}
      <div className="form-group">
        <label>Action</label>
        <select
          value={actionType}
          onChange={(e) => { setActionType(Number(e.target.value)); setActionToken(''); setSecondToken(''); }}
          disabled={!isTop}
          style={{ width: '100%' }}
        >
          <option value={0}>Send PLS — send to marketing wallet</option>
          <option value={1}>Buy & Burn — swap PLS → token → burn</option>
          <option value={2}>Add & Burn LP — add liquidity → LP to dead</option>
          <option value={3}>Custom — arbitrary call</option>
        </select>
      </div>

      {/* Amount */}
      <div className="form-group">
        <label>
          Amount (PLS)
          {availableBalance !== undefined && (
            <span style={{ marginLeft: 10, fontSize: 12, color: 'var(--text)' }}>
              Available: <strong>{fmtTok(availableBalance)} PLS</strong>
              {availableBalance > 0n && (
                <button
                  type="button"
                  className="btn-link"
                  style={{ marginLeft: 8 }}
                  onClick={() => setAmount(formatEther(availableBalance))}
                  disabled={!isTop}
                >
                  Max
                </button>
              )}
            </span>
          )}
        </label>
        <input
          type="text"
          placeholder="0.0"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          disabled={!isTop}
          style={{ width: '100%', borderColor: exceedsTreasury ? 'var(--red)' : undefined }}
        />
      </div>

      {/* Token selector for BuyAndBurn */}
      {actionType === 1 && (
        <div className="form-group">
          <label>Token to buy & burn</label>
          <select
            value={actionToken}
            onChange={(e) => setActionToken(e.target.value)}
            disabled={!isTop}
            style={{ width: '100%' }}
          >
            <option value="">— select token —</option>
            {tokensForBurn.map(t => (
              <option key={t.address} value={t.address}>{t.symbol} ({shortAddr(t.address)})</option>
            ))}
          </select>
        </div>
      )}

      {/* Token selectors for AddAndBurnLP */}
      {actionType === 2 && (
        <>
          <div className="form-group">
            <label>Token</label>
            <select
              value={actionToken}
              onChange={(e) => setActionToken(e.target.value)}
              disabled={!isTop}
              style={{ width: '100%' }}
            >
              <option value="">— select token —</option>
              {whitelistedTokens.map(t => (
                <option key={t.address} value={t.address}>{t.symbol} ({shortAddr(t.address)})</option>
              ))}
            </select>
          </div>
          <div className="form-group">
            <label>Pair with</label>
            <select
              value={secondToken}
              onChange={(e) => setSecondToken(e.target.value)}
              disabled={!isTop}
              style={{ width: '100%' }}
            >
              <option value="">PLS (native)</option>
              {whitelistedTokens
                .filter(t => t.address !== actionToken)
                .map(t => (
                  <option key={t.address} value={t.address}>{t.symbol} ({shortAddr(t.address)})</option>
                ))}
            </select>
          </div>
        </>
      )}

      {/* Custom call fields */}
      {actionType === 3 && (
        <>
          <div className="form-group">
            <label>Target address</label>
            <input
              type="text"
              placeholder="0x…"
              value={customTarget}
              onChange={(e) => setCustomTarget(e.target.value)}
              disabled={!isTop}
              style={{
                width: '100%',
                fontFamily: 'var(--mono)',
                fontSize: 13,
                borderColor: customTarget && !isAddress(customTarget) ? 'var(--red)' : undefined,
              }}
            />
          </div>
          <div className="form-group">
            <label>Calldata (hex)</label>
            <input
              type="text"
              placeholder="0x…"
              value={customData}
              onChange={(e) => setCustomData(e.target.value)}
              disabled={!isTop}
              style={{ width: '100%', fontFamily: 'var(--mono)', fontSize: 13 }}
            />
          </div>
        </>
      )}

      <div className="form-group">
        <label>Description</label>
        <textarea
          placeholder="Purpose of this proposal…"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          disabled={!isTop}
          rows={3}
          style={{ width: '100%', resize: 'vertical' }}
        />
      </div>

      {warning && (
        <p style={{ fontSize: 13, color: 'var(--red)', marginBottom: 10 }}>{warning}</p>
      )}

      <button
        onClick={handleCreate}
        disabled={
          !isTop || busy || isOnWrongChain || !inputsComplete ||
          exceedsTreasury || !!simError || isSimulating
        }
      >
        {isSimulating ? 'Simulating…' : 'Submit'}
      </button>
    </div>
  );
}

function CommentsSection({ proposalId, expanded }) {
  const { address } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const [comments, setComments] = useState([]);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState(null);

  const fetchComments = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API_BASE}/api/comments/${proposalId}`);
      if (!res.ok) throw new Error('Failed to load comments');
      const data = await res.json();
      setComments(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [proposalId]);

  useEffect(() => {
    if (expanded) fetchComments();
  }, [expanded, fetchComments]);

  const handlePost = async () => {
    if (!message.trim() || !address) return;
    setPosting(true);
    setError(null);
    try {
      const text = message.trim();
      const sigMsg = `Comment on proposal #${proposalId}: ${text}`;
      const signature = await signMessageAsync({ message: sigMsg });
      const res = await fetch(`${API_BASE}/api/comments`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ proposalId, address, message: text, signature }),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || 'Failed to post comment');
      }
      setMessage('');
      await fetchComments();
    } catch (err) {
      if (err.name !== 'UserRejectedRequestError') {
        setError(err.message);
      }
    } finally {
      setPosting(false);
    }
  };

  return (
    <div className="comments-section">
      <h4 style={{ margin: '16px 0 10px', color: 'var(--text-bright)', fontSize: 14 }}>
        Comments {comments.length > 0 ? `(${comments.length})` : ''}
      </h4>

      {loading && <p style={{ fontSize: 12, color: 'var(--text)' }}>Loading comments...</p>}
      {error && <p style={{ fontSize: 12, color: 'var(--red)' }}>{error}</p>}

      {!loading && comments.length === 0 && (
        <p style={{ fontSize: 12, color: 'var(--text)' }}>No comments yet. Be the first to comment.</p>
      )}

      <div className="comments-list">
        {comments.map((c, i) => (
          <div key={c.id || i} className="comment-card">
            <div className="comment-avatar">
              {(c.address || '0x').slice(2, 4).toUpperCase()}
            </div>
            <div className="comment-body">
              <div className="comment-header">
                <a
                  href={`https://otter.pulsechain.com/address/${c.address}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="address-link"
                  style={{ fontSize: 12 }}
                >
                  {shortAddr(c.address)}
                </a>
                <span className="comment-time">{relativeTime(c.createdAt || c.timestamp)}</span>
              </div>
              <p className="comment-text">{c.message}</p>
            </div>
          </div>
        ))}
      </div>

      {address && (
        <div className="comment-form">
          <textarea
            placeholder="Add a comment..."
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            rows={2}
            className="comment-textarea"
          />
          <button
            onClick={handlePost}
            disabled={posting || !message.trim()}
            className="comment-post-btn"
          >
            {posting ? 'Posting...' : 'Post Comment'}
          </button>
        </div>
      )}
    </div>
  );
}
