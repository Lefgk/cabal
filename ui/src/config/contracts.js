export const CHAIN_ID = 369;

export const ADDRESSES = {
  stakingVault: '0x1DdDfF8D36bb2561119868C2D5C2E99F50ED0843',
  treasuryDAO: '0x81f812eA3902D461A0207493C5D7f656A00e5c46',
  stakeToken: '0xFbA28dA172e60E9CA50985C51E3772f715FAba20',
};

// Block at which the current TreasuryDAO was deployed — used as fromBlock
// when fetching TokenWhitelisted / TokenRemovedFromWhitelist events so we
// don't scan from genesis.
export const DAO_DEPLOY_BLOCK = 26363214n;
