// Source of a mocked EIP-1193 provider that the tests inject into the page
// *before* the React app boots. Reads (eth_call, eth_getBalance, multicall,
// block number, gas, nonce, etc.) are forwarded to a real PulseChain RPC so
// the UI renders live on-chain state. Writes (eth_sendTransaction) are
// captured on `window.__SENT_TXS__` and return a fake hash plus a synthetic
// successful receipt so wagmi resolves without touching mainnet.
//
// The test passes the desired account via `window.__MOCK_ACCOUNT__`, set on
// the page before this script runs. See `injectWallet()` in the specs.

export const MOCK_PROVIDER_SOURCE = `
(function installMockProvider() {
  const RPC_URLS = [
    'https://rpc.pulsechain.com',
    'https://rpc-pulsechain.g4mm4.io',
    'https://pulsechain-rpc.publicnode.com',
  ];
  const CHAIN_ID_HEX = '0x171'; // 369
  const CHAIN_ID_DEC = '369';
  const ACCOUNT = (window.__MOCK_ACCOUNT__ || '0x000000000000000000000000000000000000dEaD').toLowerCase();
  const FAKE_TX_HASH = '0x' + '11'.repeat(32);
  const FAKE_BLOCK_HASH = '0x' + '22'.repeat(32);

  const sentTxs = [];
  const rpcLog = [];
  window.__SENT_TXS__ = sentTxs;
  window.__RPC_LOG__ = rpcLog;
  window.__MOCK_READY__ = true;
  // Tell useSafeWriteContract to skip its eth_call preflight. Real on-chain
  // state for the mock account won't pass every simulation (e.g. stake
  // without allowance), but the tests only need to assert the tx shape.
  window.__TEST_SKIP_SIM__ = true;

  let rpcIdx = 0;
  async function rpcForward(method, params) {
    let lastErr;
    for (let attempt = 0; attempt < RPC_URLS.length; attempt++) {
      const url = RPC_URLS[(rpcIdx + attempt) % RPC_URLS.length];
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: Math.floor(Math.random() * 1e9),
            method,
            params: params || [],
          }),
        });
        const j = await res.json();
        if (j.error) throw new Error(j.error.message || 'rpc error');
        rpcIdx = (rpcIdx + attempt) % RPC_URLS.length;
        return j.result;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr || new Error('all RPCs failed');
  }

  const listeners = {};
  function emit(event, data) {
    (listeners[event] || []).forEach((cb) => {
      try { cb(data); } catch (_) { /* ignore */ }
    });
  }

  const provider = {
    isMetaMask: true,
    isConnected: () => true,
    chainId: CHAIN_ID_HEX,
    networkVersion: CHAIN_ID_DEC,
    selectedAddress: ACCOUNT,

    request: async ({ method, params }) => {
      rpcLog.push({ method, params });
      switch (method) {
        case 'eth_chainId':
          return CHAIN_ID_HEX;
        case 'net_version':
          return CHAIN_ID_DEC;
        case 'eth_accounts':
        case 'eth_requestAccounts':
          return [ACCOUNT];
        case 'wallet_switchEthereumChain':
        case 'wallet_addEthereumChain':
          return null;
        case 'wallet_requestPermissions':
          return [{ parentCapability: 'eth_accounts' }];
        case 'wallet_getPermissions':
          return [{ parentCapability: 'eth_accounts' }];

        case 'eth_sendTransaction': {
          const tx = (params && params[0]) || {};
          sentTxs.push({
            ...tx,
            capturedAt: Date.now(),
          });
          return FAKE_TX_HASH;
        }

        case 'eth_getTransactionReceipt': {
          if ((params && params[0]) === FAKE_TX_HASH) {
            return {
              transactionHash: FAKE_TX_HASH,
              transactionIndex: '0x0',
              blockNumber: '0x1',
              blockHash: FAKE_BLOCK_HASH,
              from: ACCOUNT,
              to: null,
              gasUsed: '0x5208',
              cumulativeGasUsed: '0x5208',
              logs: [],
              logsBloom: '0x' + '00'.repeat(256),
              contractAddress: null,
              type: '0x2',
              effectiveGasPrice: '0x1',
              status: '0x1',
            };
          }
          return await rpcForward(method, params);
        }

        case 'eth_getTransactionByHash': {
          if ((params && params[0]) === FAKE_TX_HASH) {
            return {
              hash: FAKE_TX_HASH,
              nonce: '0x0',
              blockHash: FAKE_BLOCK_HASH,
              blockNumber: '0x1',
              transactionIndex: '0x0',
              from: ACCOUNT,
              to: null,
              value: '0x0',
              gas: '0x5208',
              gasPrice: '0x1',
              input: '0x',
            };
          }
          return await rpcForward(method, params);
        }

        // Gas / nonce / signing prep → forward so wagmi can build the tx
        // against live PulseChain state for the fake account.
        default:
          return await rpcForward(method, params);
      }
    },

    on: (event, cb) => {
      (listeners[event] = listeners[event] || []).push(cb);
    },
    removeListener: (event, cb) => {
      if (listeners[event]) {
        listeners[event] = listeners[event].filter((x) => x !== cb);
      }
    },
    removeAllListeners: () => {
      for (const k of Object.keys(listeners)) delete listeners[k];
    },
    // EIP-1193 legacy shims some libs still sniff for
    enable: async () => [ACCOUNT],
    send: (methodOrPayload, paramsOrCallback) => {
      if (typeof methodOrPayload === 'string') {
        return provider.request({ method: methodOrPayload, params: paramsOrCallback });
      }
      if (typeof paramsOrCallback === 'function') {
        provider.request(methodOrPayload).then(
          (result) => paramsOrCallback(null, { jsonrpc: '2.0', id: methodOrPayload.id, result }),
          (err) => paramsOrCallback(err),
        );
        return;
      }
      return provider.request(methodOrPayload);
    },
    sendAsync: (payload, cb) => {
      provider.request(payload).then(
        (result) => cb(null, { jsonrpc: '2.0', id: payload.id, result }),
        (err) => cb(err),
      );
    },
  };

  Object.defineProperty(window, 'ethereum', {
    value: provider,
    writable: true,
    configurable: true,
  });

  // Fire after install so listeners attached post-load still see "connected".
  setTimeout(() => emit('accountsChanged', [ACCOUNT]), 0);
  setTimeout(() => emit('chainChanged', CHAIN_ID_HEX), 0);
})();
`;
