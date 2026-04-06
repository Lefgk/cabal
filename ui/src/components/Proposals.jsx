import { useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract } from 'wagmi';
import { formatEther, parseEther, zeroAddress } from 'viem';
import { ADDRESSES } from '../config/contracts.js';
import { TREASURY_DAO_ABI, STAKING_VAULT_ABI } from '../config/abis.js';

const daoAddr = ADDRESSES.treasuryDAO;
const vaultAddr = ADDRESSES.stakingVault;

const PROPOSAL_TYPES = ['BuyAndBurn', 'Marketing', 'LP', 'Custom'];
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
        Proposals let the community decide how to spend Treasury funds. Only top stakers can create proposals. All stakers can vote — your voting power equals your staked balance. Proposals need to meet the quorum threshold and get majority "Yes" votes to pass. Once passed, anyone can execute the proposal on-chain.
      </p>

      <div className="help-box" style={{ marginBottom: 16 }}>
        <p className="help-text" style={{ marginBottom: 6 }}><strong style={{ color: 'var(--text-bright)' }}>Proposal Types:</strong></p>
        <ul className="help-list">
          <li><strong>BuyAndBurn</strong> — Uses WPLS from Treasury to buy tokens on PulseX, then burns them. Reduces supply.</li>
          <li><strong>Marketing</strong> — Sends WPLS to a target wallet for marketing expenses.</li>
          <li><strong>LP</strong> — Sends WPLS to a target address for adding liquidity on PulseX.</li>
          <li><strong>Custom</strong> — Sends WPLS to any address for any other purpose described in the proposal.</li>
        </ul>
      </div>

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
  const typeLabel = PROPOSAL_TYPES[p.pType] || 'Unknown';

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
        <span>Type: <strong>{typeLabel}</strong></span>
        <span>Amount: <strong>{fmt(p.amount)} WPLS</strong></span>
        <span>Target: <code style={{ fontSize: 12 }}>{p.target}</code></span>
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
  const [pType, setPType] = useState(0);
  const [amount, setAmount] = useState('');
  const [target, setTarget] = useState('');
  const [description, setDescription] = useState('');

  const handleCreate = () => {
    if (!description || !amount) return;
    writeContract({
      address: ADDRESSES.treasuryDAO, abi: TREASURY_DAO_ABI, functionName: 'propose',
      args: [pType, parseEther(amount), target || zeroAddress, description],
    });
    setAmount('');
    setTarget('');
    setDescription('');
  };

  return (
    <div style={{ marginTop: 24, paddingTop: 20, borderTop: '1px solid var(--border)' }}>
      <h3>Create Proposal</h3>
      <p className="help-text" style={{ marginBottom: 14 }}>
        As a top staker, you can create proposals to spend Treasury WPLS. Choose a type, specify the amount of WPLS to spend, and provide a target address. For BuyAndBurn, the target is ignored (tokens are bought and burned automatically). For Marketing/LP/Custom, the target is the wallet that will receive the WPLS.
      </p>

      <div className="form-group">
        <label>Type</label>
        <select value={pType} onChange={(e) => setPType(Number(e.target.value))} style={{ width: '100%' }}>
          {PROPOSAL_TYPES.map((t, i) => (
            <option key={i} value={i}>{t}</option>
          ))}
        </select>
      </div>

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
        <label>Target Address — The wallet that receives funds (ignored for BuyAndBurn)</label>
        <input
          type="text"
          placeholder="0x... (leave empty for BuyAndBurn)"
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          style={{ width: '100%', fontFamily: 'var(--mono)', fontSize: 13 }}
        />
      </div>

      <div className="form-group">
        <label>Description</label>
        <textarea
          placeholder="Describe your proposal..."
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          rows={3}
          style={{ width: '100%', resize: 'vertical' }}
        />
      </div>

      <button onClick={handleCreate} disabled={isWriting || !description || !amount}>
        Submit Proposal
      </button>
    </div>
  );
}
