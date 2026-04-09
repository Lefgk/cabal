import { useState } from 'react';
import { useAccount } from 'wagmi';
import { useReadContract, useReadContracts, useSafeWriteContract } from '../hooks/usePls.js';
import { formatEther, parseEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI } from '../config/abis.js';
import TokenIcon from './TokenIcon.jsx';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;

const STATE_LABELS = ['Pending', 'Active', 'Succeeded', 'Defeated', 'Executed'];
const STATE_CLASSES = ['badge-pending', 'badge-active', 'badge-succeeded', 'badge-defeated', 'badge-executed'];

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

export default function Proposals() {
  const { address } = useAccount();
  const {
    writeContract,
    isPending: isWriting,
    isMining,
    isOnWrongChain,
  } = useSafeWriteContract();
  const busy = isWriting || isMining;

  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address], query: { enabled: !!address },
  });
  const { data: proposalCount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'proposalCount',
  });
  const { data: totalStaked } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'totalStaked',
  });
  const { data: quorumBps } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'quorumBps',
  });

  const count = proposalCount ? Number(proposalCount) : 0;

  const proposalCalls = [];
  for (let i = 0; i < count; i++) {
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

  // Quorum requirement in wei
  const quorumRequired = (totalStaked && quorumBps)
    ? (totalStaked * quorumBps) / 10000n
    : 0n;

  return (
    <div className="card">
      <h2>Proposals ({count})</h2>
      <p className="help-text">
        Top stakers propose, all stakers vote (weight = stake). Needs quorum + majority Yes to pass.
      </p>

      {count === 0 && <p style={{ color: 'var(--text)' }}>No proposals yet.</p>}

      {/* Newest first */}
      {[...proposals].reverse().map((p) => (
        <ProposalCard
          key={Number(p.id)}
          proposal={p}
          address={address}
          busy={busy}
          isOnWrongChain={isOnWrongChain}
          writeContract={writeContract}
          quorumRequired={quorumRequired}
        />
      ))}

      <CreateProposalForm
        writeContract={writeContract}
        busy={busy}
        isOnWrongChain={isOnWrongChain}
        address={address}
        isTop={isTop}
      />
      {address && isOnWrongChain && (
        <p className="help-text" style={{ marginTop: 8, color: 'var(--danger, #c33)' }}>
          Switch your wallet to PulseChain (369) to vote or propose.
        </p>
      )}
      {isMining && (
        <p className="help-text" style={{ marginTop: 8 }}>Waiting for confirmation…</p>
      )}
    </div>
  );
}

function ProposalCard({ proposal, address, busy, isOnWrongChain, writeContract, quorumRequired }) {
  const p = proposal;
  const [expanded, setExpanded] = useState(false);

  const stateLabel = STATE_LABELS[p.state] || 'Unknown';
  const stateClass = STATE_CLASSES[p.state] || 'badge-pending';

  const totalVotes = p.yesVotes + p.noVotes;
  const yesPct = totalVotes > 0n ? Number((p.yesVotes * 10000n) / totalVotes) / 100 : 0;
  const noPct = totalVotes > 0n ? 100 - yesPct : 0;

  const now = Math.floor(Date.now() / 1000);
  const timeLeft = Number(p.endTime) - now;
  const isActive = p.state === 1;
  const isSucceeded = p.state === 2;

  // Quorum progress
  const quorumPct = quorumRequired > 0n
    ? Math.min(100, Number((totalVotes * 10000n) / quorumRequired) / 100)
    : 0;
  const quorumMet = quorumRequired > 0n && totalVotes >= quorumRequired;

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

  return (
    <div className="proposal-card" onClick={() => setExpanded(!expanded)} style={{ cursor: 'pointer' }}>
      <div className="proposal-header">
        <h3 style={{ margin: 0 }}>#{Number(p.id)} — {p.description}</h3>
        <span className={`badge ${stateClass}`}>{stateLabel}</span>
      </div>

      {/* Primary stats */}
      <div className="proposal-meta">
        <span><strong><TokenIcon symbol="WPLS" />{fmtTok(p.amount)} WPLS</strong> → <a href={`https://otter.pulsechain.com/address/${p.target}`} target="_blank" rel="noopener noreferrer" className="address-link" onClick={(e) => e.stopPropagation()}>{shortAddr(p.target)}</a></span>
        <span>{isActive ? `Ends in ${fmtCountdown(timeLeft)}` : `Ended ${fmtDate(p.endTime)}`}</span>
      </div>

      {/* Vote totals */}
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

      {/* Quorum progress */}
      {quorumRequired > 0n && (
        <div style={{ marginTop: 8, fontSize: 12, color: 'var(--text)' }}>
          Quorum: {fmtTok(totalVotes)} / {fmtTok(quorumRequired)} {quorumMet ? '✓' : ''}
          <div style={{ background: 'var(--border)', height: 4, borderRadius: 2, marginTop: 4, overflow: 'hidden' }}>
            <div style={{ width: `${quorumPct}%`, height: '100%', background: quorumMet ? 'var(--green)' : 'var(--accent, #7c3aed)' }} />
          </div>
        </div>
      )}

      {/* Expandable details */}
      {expanded && (
        <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid var(--border)', fontSize: 12, color: 'var(--text)' }}>
          <div><strong>Proposer:</strong> <a href={`https://otter.pulsechain.com/address/${p.proposer}`} target="_blank" rel="noopener noreferrer" className="address-link" onClick={(e) => e.stopPropagation()}>{p.proposer}</a></div>
          <div><strong>Created:</strong> {fmtDate(p.startTime)}</div>
          <div><strong>Executed:</strong> {p.executed ? 'Yes' : 'No'}</div>
        </div>
      )}

      {/* Actions */}
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

function CreateProposalForm({ writeContract, busy, isOnWrongChain, address, isTop }) {
  const [amount, setAmount] = useState('');
  const [target, setTarget] = useState('');
  const [description, setDescription] = useState('');

  const handleCreate = () => {
    if (!description || !amount || !target) return;
    writeContract({
      address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'propose',
      args: [parseEther(amount), target, description],
    });
    setAmount('');
    setTarget('');
    setDescription('');
  };

  const gateMsg = !address
    ? 'Connect wallet to propose.'
    : !isTop
      ? 'Only top-100 stakers can create proposals. Stake more to qualify.'
      : null;

  return (
    <div style={{ marginTop: 24, paddingTop: 20, borderTop: '1px solid var(--border)' }}>
      <h3>Create Proposal</h3>
      {gateMsg && <p className="help-text" style={{ marginBottom: 12 }}>{gateMsg}</p>}

      <div className="form-group">
        <label>Amount (WPLS)</label>
        <input
          type="text"
          placeholder="0.0"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          disabled={!isTop}
          style={{ width: '100%' }}
        />
      </div>

      <div className="form-group">
        <label>Target address</label>
        <input
          type="text"
          placeholder="0x…"
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          disabled={!isTop}
          style={{ width: '100%', fontFamily: 'var(--mono)', fontSize: 13 }}
        />
      </div>

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

      <button
        onClick={handleCreate}
        disabled={!isTop || busy || isOnWrongChain || !description || !amount || !target}
      >
        Submit
      </button>
    </div>
  );
}
