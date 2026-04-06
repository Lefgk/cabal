import { useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract } from 'wagmi';
import { formatEther, parseEther } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI } from '../config/abis.js';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;

const STATE_LABELS = ['Pending', 'Active', 'Succeeded', 'Defeated', 'Executed'];
const STATE_CLASSES = ['badge-pending', 'badge-active', 'badge-succeeded', 'badge-defeated', 'badge-executed'];

export default function Proposals() {
  const { address } = useAccount();
  const { writeContract, isPending: isWriting } = useWriteContract();

  // Check if user is top staker
  const { data: isTop } = useReadContract({
    address: vaultAddr, abi: STAKING_VAULT_ABI, functionName: 'isTopStaker',
    args: [address], query: { enabled: !!address },
  });

  // Get proposal count
  const { data: proposalCount } = useReadContract({
    address: daoAddr, abi: TREASURY_DAO_ABI, functionName: 'proposalCount',
  });

  const count = proposalCount ? Number(proposalCount) : 0;

  // Build multicall for all proposals + their states
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

  // Parse results into proposal objects
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

  return (
    <div className="card">
      <h2>Proposals</h2>
      <p className="help-text">
        Proposals let the community decide how to spend Treasury WPLS. Only top stakers can create proposals. All stakers can vote — your voting power equals your staked balance. Proposals need to meet the quorum threshold and get majority "Yes" votes to pass. Once passed, anyone can execute the proposal on-chain, which sends the WPLS to the target address.
      </p>

      {count === 0 && <p style={{ color: 'var(--text)' }}>No proposals yet.</p>}

      {proposals.map((p) => (
        <ProposalCard key={Number(p.id)} proposal={p} address={address} isWriting={isWriting} writeContract={writeContract} />
      ))}

      {isTop && <CreateProposalForm writeContract={writeContract} isWriting={isWriting} />}
    </div>
  );
}

function ProposalCard({ proposal, address, isWriting, writeContract }) {
  const p = proposal;
  const stateLabel = STATE_LABELS[p.state] || 'Unknown';
  const stateClass = STATE_CLASSES[p.state] || 'badge-pending';

  const totalVotes = p.yesVotes + p.noVotes;
  const yesPct = totalVotes > 0n ? Number((p.yesVotes * 100n) / totalVotes) : 0;
  const noPct = totalVotes > 0n ? 100 - yesPct : 0;

  const fmt = (val) => Number(formatEther(val)).toLocaleString(undefined, { maximumFractionDigits: 4 });

  // Check if user already voted
  const { data: receipt } = useReadContract({
    address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'getReceipt',
    args: [p.id, address],
    query: { enabled: !!address },
  });

  const hasVoted = receipt?.hasVoted;
  const isActive = p.state === 1;
  const isSucceeded = p.state === 2;

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
    <div className="proposal-card">
      <div className="proposal-header">
        <h3 style={{ margin: 0 }}>#{Number(p.id)}: {p.description}</h3>
        <span className={`badge ${stateClass}`}>{stateLabel}</span>
      </div>
      <div className="proposal-meta">
        <span>Amount: <strong>{fmt(p.amount)} WPLS</strong></span>
        <span>Target: <a href={`https://otter.pulsechain.com/address/${p.target}`} target="_blank" rel="noopener noreferrer" className="address-link" style={{ fontSize: 12 }}>{p.target}</a></span>
        <span>Proposer: <a href={`https://otter.pulsechain.com/address/${p.proposer}`} target="_blank" rel="noopener noreferrer" className="address-link" style={{ fontSize: 12 }}>{p.proposer}</a></span>
      </div>

      {/* Vote bar */}
      <div className="proposal-meta">
        <span style={{ color: 'var(--green)' }}>Yes: {fmt(p.yesVotes)}</span>
        <span style={{ color: 'var(--red)' }}>No: {fmt(p.noVotes)}</span>
      </div>
      {totalVotes > 0n && (
        <div className="vote-bar">
          <div className="vote-bar-yes" style={{ width: `${yesPct}%` }} />
          <div className="vote-bar-no" style={{ width: `${noPct}%` }} />
        </div>
      )}

      {/* Actions */}
      {isActive && !hasVoted && (
        <div className="vote-buttons">
          <button className="btn-green" onClick={() => handleVote(true)} disabled={isWriting}>
            Vote Yes
          </button>
          <button className="btn-red" onClick={() => handleVote(false)} disabled={isWriting}>
            Vote No
          </button>
        </div>
      )}
      {isActive && hasVoted && (
        <p style={{ fontSize: 13, color: 'var(--text)', marginTop: 8 }}>
          You voted {receipt?.support ? 'Yes' : 'No'}
        </p>
      )}
      {isSucceeded && (
        <div style={{ marginTop: 8 }}>
          <button className="btn-blue" onClick={handleExecute} disabled={isWriting}>
            Execute Proposal
          </button>
        </div>
      )}
    </div>
  );
}

function CreateProposalForm({ writeContract, isWriting }) {
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

  return (
    <div style={{ marginTop: 24, paddingTop: 20, borderTop: '1px solid var(--border)' }}>
      <h3>Create Proposal</h3>
      <p className="help-text" style={{ marginBottom: 14 }}>
        As a top staker, you can create proposals to spend Treasury WPLS. Specify how much WPLS, who receives it, and describe the purpose (buy & burn, marketing, LP, etc). The community votes, and if it passes, the WPLS is sent to the target address.
      </p>

      <div className="form-group">
        <label>Amount (WPLS) — How much WPLS to spend from the Treasury</label>
        <input
          type="text"
          placeholder="0.0"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          style={{ width: '100%' }}
        />
      </div>

      <div className="form-group">
        <label>Target Address — The wallet that will receive the WPLS</label>
        <input
          type="text"
          placeholder="0x..."
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          style={{ width: '100%', fontFamily: 'var(--mono)', fontSize: 13 }}
        />
      </div>

      <div className="form-group">
        <label>Description — Explain the purpose of this proposal</label>
        <textarea
          placeholder="e.g. Buy and burn 500 WPLS worth of tokens, Marketing budget for Q2, Add liquidity on PulseX..."
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          rows={3}
          style={{ width: '100%', resize: 'vertical' }}
        />
      </div>

      <button onClick={handleCreate} disabled={isWriting || !description || !amount || !target}>
        Submit Proposal
      </button>
    </div>
  );
}
