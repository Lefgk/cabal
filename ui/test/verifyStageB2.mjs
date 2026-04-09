// On-chain smoke test for the Stage B2 deployment.
// Reads every piece of state the UI depends on and asserts it is wired
// correctly. No wallet / broadcast — read-only against the live RPC.
//
// Run with:
//   node ui/test/verifyStageB2.mjs
//
// Tries local node first, falls back to public RPC.

import { createPublicClient, http, getAddress, formatEther, formatUnits } from 'viem';

// ── Expected wiring (MUST match script/StageB2.s.sol + contracts.js) ─────────
const EXPECTED = {
  token:        '0x1745A8154C134840e4D4F6A84dD109902d52A33b',
  vault:        '0x57124b4E6b44401D96D3b39b094923c5832dC769',
  dao:          '0xE27E3963cDF3B881a467f259318ca793076B42A1',
  pair:         '0x578c818fb74478B4a917C611D2C8Bb3A944B9f3a',
  pHEX:         '0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39',
  wpls:         '0xA1077a294dDE1B09bB078844df40758a5D0f9a27',
  router:       '0x165C3410fC91EF562C50559f7d2289fEbed552d9',
  factory:      '0x1715a3E4A142d8b698131108995174F37aEBA10D',
  extBurnToken: '0x90F055196778e541018482213Ca50648cEA1a050',
  dead:         '0x000000000000000000000000000000000000dEaD',
  dev:          '0xa0419404eF7b81d9Ec64367eb68e5f425EACE618',
};

// ── Minimal ABIs ─────────────────────────────────────────────────────────────
const ERC20_ABI = [
  { name: 'name',        type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { name: 'symbol',      type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { name: 'decimals',    type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { name: 'totalSupply', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'balanceOf',   type: 'function', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
];

const TOKEN_EXTRA_ABI = [
  { name: 'tradingEnabled', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { name: 'owner',          type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  {
    name: 'taxes', type: 'function', stateMutability: 'view',
    inputs: [{ type: 'uint256' }],
    outputs: [
      { name: 'taxMoment',    type: 'uint8'  },
      { name: 'taxType',      type: 'uint8'  },
      { name: 'field2',       type: 'uint8'  },
      { name: 'bps',          type: 'uint256'},
      { name: 'wallet',       type: 'address'},
      { name: 'tokenAddress', type: 'address'},
      { name: 'burnAddress',  type: 'address'},
      { name: 'rewardInPls',  type: 'bool'   },
      { name: 'field8',       type: 'uint256'},
    ],
  },
];

const VAULT_ABI = [
  { name: 'owner',          type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'paused',         type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool'    }] },
  { name: 'stakingToken',   type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'rewardsToken',   type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'dexRouter',      type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'daoAddress',     type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'totalStaked',    type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'rewardRate',     type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'rewardsDuration',type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'periodFinish',   type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];

const DAO_ABI = [
  { name: 'owner',        type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'token',        type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'wpls',         type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'dexRouter',    type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'stakingVault', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'votingPeriod', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'quorumBps',    type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];

// ── Runner ───────────────────────────────────────────────────────────────────
let pass = 0, fail = 0;
function check(label, ok, detail = '') {
  const tag = ok ? 'PASS' : 'FAIL';
  const prefix = ok ? '\x1b[32m' : '\x1b[31m';
  console.log(`${prefix}[${tag}]\x1b[0m ${label}${detail ? '  — ' + detail : ''}`);
  if (ok) pass++; else fail++;
}
function eqAddr(a, b) { return getAddress(a) === getAddress(b); }

async function makeClient() {
  const rpcs = ['http://localhost:8545', 'https://rpc.pulsechain.com'];
  for (const url of rpcs) {
    try {
      const c = createPublicClient({ transport: http(url) });
      const id = await c.getChainId();
      if (id !== 369) throw new Error('wrong chain');
      console.log(`RPC: ${url} (chain ${id})`);
      return c;
    } catch (e) {
      console.log(`RPC ${url} unavailable: ${e.message.split('\n')[0]}`);
    }
  }
  throw new Error('no usable RPC');
}

async function main() {
  const client = await makeClient();
  const tokenAddr = getAddress(EXPECTED.token);
  const vaultAddr = getAddress(EXPECTED.vault);
  const daoAddr   = getAddress(EXPECTED.dao);

  // ── 1. Token basic metadata ────────────────────────────────────────────
  console.log('\n── Token ──');
  const [name, sym, dec, supply, tradingEnabled, tokenOwner] = await Promise.all([
    client.readContract({ address: tokenAddr, abi: ERC20_ABI,       functionName: 'name' }),
    client.readContract({ address: tokenAddr, abi: ERC20_ABI,       functionName: 'symbol' }),
    client.readContract({ address: tokenAddr, abi: ERC20_ABI,       functionName: 'decimals' }),
    client.readContract({ address: tokenAddr, abi: ERC20_ABI,       functionName: 'totalSupply' }),
    client.readContract({ address: tokenAddr, abi: TOKEN_EXTRA_ABI, functionName: 'tradingEnabled' }),
    client.readContract({ address: tokenAddr, abi: TOKEN_EXTRA_ABI, functionName: 'owner' }),
  ]);
  check('name == "testt"',                name === 'testt', name);
  check('symbol == "TSTT"',               sym === 'TSTT', sym);
  check('decimals == 18',                 Number(dec) === 18, String(dec));
  check('totalSupply == 1B ether',        supply === 1_000_000_000n * 10n ** 18n, formatEther(supply));
  check('tradingEnabled',                 tradingEnabled === true);
  check('owner == dev wallet',            eqAddr(tokenOwner, EXPECTED.dev), tokenOwner);

  // ── 2. Taxes ───────────────────────────────────────────────────────────
  console.log('\n── Taxes ──');
  const taxes = [];
  for (let i = 0; i < 5; i++) {
    taxes.push(await client.readContract({ address: tokenAddr, abi: TOKEN_EXTRA_ABI, functionName: 'taxes', args: [BigInt(i)] }));
  }
  // Expected per StageB2 script:
  //   i=0: Dev 3.25% PLS → vault
  //   i=1: Dev 1.00% PLS → dao
  //   i=2: Liquify 0.25%
  //   i=3: ExtBurn 0.25% → ZKP → dead
  //   i=4: Burn 0.25% self → dead
  check('tax[0] is Dev (type 2) 3.25%',    Number(taxes[0][1]) === 2 && Number(taxes[0][3]) === 325);
  check('tax[0] rewardInPls == true',      taxes[0][7] === true);
  check('tax[0] receiver == vault',        eqAddr(taxes[0][4], vaultAddr), taxes[0][4]);

  check('tax[1] is Dev (type 2) 1.00%',    Number(taxes[1][1]) === 2 && Number(taxes[1][3]) === 100);
  check('tax[1] rewardInPls == true',      taxes[1][7] === true);
  check('tax[1] receiver == DAO',          eqAddr(taxes[1][4], daoAddr), taxes[1][4]);

  check('tax[2] is Liquify (type 5) 0.25%',Number(taxes[2][1]) === 5 && Number(taxes[2][3]) === 25);

  check('tax[3] is ExtBurn (type 1) 0.25%',Number(taxes[3][1]) === 1 && Number(taxes[3][3]) === 25);
  check('tax[3] tokenAddress == ZKP',      eqAddr(taxes[3][5], EXPECTED.extBurnToken), taxes[3][5]);
  check('tax[3] burnAddress == dead',      eqAddr(taxes[3][6], EXPECTED.dead), taxes[3][6]);

  check('tax[4] is Burn (type 0) 0.25%',   Number(taxes[4][1]) === 0 && Number(taxes[4][3]) === 25);
  check('tax[4] burnAddress == dead',      eqAddr(taxes[4][6], EXPECTED.dead), taxes[4][6]);

  // ── 3. Vault wiring ────────────────────────────────────────────────────
  console.log('\n── Vault ──');
  const [vOwner, vPaused, vStake, vRwd, vRouter, vDao] = await Promise.all([
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'owner' }),
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'paused' }),
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'stakingToken' }),
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'rewardsToken' }),
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'dexRouter' }),
    client.readContract({ address: vaultAddr, abi: VAULT_ABI, functionName: 'daoAddress' }),
  ]);
  check('vault.owner == dev wallet',       eqAddr(vOwner, EXPECTED.dev), vOwner);
  check('vault NOT paused',                vPaused === false);
  check('vault.stakingToken == TSTT',      eqAddr(vStake, tokenAddr), vStake);
  check('vault.rewardsToken == pHEX',      eqAddr(vRwd, EXPECTED.pHEX), vRwd);
  check('vault.dexRouter == PulseX',       eqAddr(vRouter, EXPECTED.router), vRouter);
  check('vault.daoAddress == new DAO',     eqAddr(vDao, daoAddr), vDao);

  // ── 4. Reward token metadata check ─────────────────────────────────────
  console.log('\n── Reward Token (pHEX) ──');
  const [rwdSym, rwdDec] = await Promise.all([
    client.readContract({ address: getAddress(EXPECTED.pHEX), abi: ERC20_ABI, functionName: 'symbol' }),
    client.readContract({ address: getAddress(EXPECTED.pHEX), abi: ERC20_ABI, functionName: 'decimals' }),
  ]);
  check('pHEX on-chain symbol == "HEX"',   rwdSym === 'HEX', rwdSym);
  check('pHEX decimals == 8',              Number(rwdDec) === 8, String(rwdDec));

  // ── 5. DAO wiring ──────────────────────────────────────────────────────
  console.log('\n── DAO ──');
  const [dOwner, dToken, dWpls, dRouter, dVault, vp, qb] = await Promise.all([
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'owner' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'token' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'wpls' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'dexRouter' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'stakingVault' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'votingPeriod' }),
    client.readContract({ address: daoAddr, abi: DAO_ABI, functionName: 'quorumBps' }),
  ]);
  check('DAO.owner == dev wallet',         eqAddr(dOwner, EXPECTED.dev), dOwner);
  check('DAO.token == new TSTT',           eqAddr(dToken, tokenAddr), dToken);
  check('DAO.wpls == WPLS',                eqAddr(dWpls, EXPECTED.wpls), dWpls);
  check('DAO.dexRouter == PulseX',         eqAddr(dRouter, EXPECTED.router), dRouter);
  check('DAO.stakingVault == new vault',   eqAddr(dVault, vaultAddr), dVault);
  check('DAO.votingPeriod > 0',            vp > 0n, String(vp));
  check('DAO.quorumBps > 0 && <= 10000',   qb > 0n && qb <= 10000n, String(qb));

  // ── 6. LP pair sanity ──────────────────────────────────────────────────
  console.log('\n── LP Pair ──');
  const pairTsttBal = await client.readContract({
    address: tokenAddr, abi: ERC20_ABI, functionName: 'balanceOf', args: [getAddress(EXPECTED.pair)],
  });
  const pairWplsBal = await client.readContract({
    address: getAddress(EXPECTED.wpls), abi: ERC20_ABI, functionName: 'balanceOf', args: [getAddress(EXPECTED.pair)],
  });
  check('LP holds TSTT (>0)',              pairTsttBal > 0n, formatEther(pairTsttBal) + ' TSTT');
  check('LP holds WPLS (>0)',              pairWplsBal > 0n, formatEther(pairWplsBal) + ' WPLS');

  // ── Summary ────────────────────────────────────────────────────────────
  console.log(`\n── Summary ──\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
