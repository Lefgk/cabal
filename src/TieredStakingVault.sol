// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPulseXRouter} from "./interfaces/IPulseXRouter.sol";

/// @title TieredStakingVault
/// @notice Multi-position weighted-lock staking vault for TSTT.
///         Tiers: FLEX 1.5x / 90D 3x / 1Y 5x / 3Y 10x.
///         Reward token: pDAI. Synthetix-style accumulator over total *effective* stake.
///         Early unlock pays 30% EES split inline:
///           69% burn TSTT  /  20% pDAI to self  /  10% PLS to OMEGA DAO Treasury  /  1% dev TSTT
///         All withdrawals (flex + expired locks) pay a 1% fee: TSTT→WPLS→pDAI → notify
///         this vault. Falls back to TSTT burn if router unset.
contract TieredStakingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────── Errors ───────────────
    error ZeroAmount();
    error ZeroAddress();
    error InvalidDuration();
    error TooManyLocks();
    error LockNotFound();
    error InvalidLockOrder();
    error InsufficientFlex();
    error ZeroPLS();
    error NoRouter();
    error SwapYieldedZero();
    error NoNewRewards();
    error PeriodNotFinished();
    error ZeroDuration();
    error CannotRecoverStaking();
    error CannotRecoverReward();
    error Insolvent();
    error RewardTooHigh();
    error IsPaused();
    error Underflow();

    // ─────────────── Constants ───────────────
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;

    uint256 public constant BPS = 10_000;
    uint256 public constant FLEX_WITHDRAW_FEE_BPS = 100;        // 1% on flex withdraw
    uint256 public constant EES_BPS = 3_000;                    // 30% early-exit on locks

    /// @dev Within EES (3000 bps total) split:
    uint256 public constant EES_BURN_BPS = 6_900;               // 69% of EES → burn TSTT
    uint256 public constant EES_PRIMARY_BPS = 2_000;            // 20% of EES → pDAI to self
    uint256 public constant EES_SECONDARY_BPS = 1_000;          // 10% of EES → PLS to OMEGA DAO Treasury
    uint256 public constant EES_DEV_BPS = 100;                  // 1% of EES → TSTT to dev

    uint256 public constant FLEX_MULT = 150;                    // 1.5x
    uint256 public constant MULT_90D = 300;                     // 3x
    uint256 public constant MULT_1Y = 500;                      // 5x
    uint256 public constant MULT_3Y = 1_000;                    // 10x

    uint256 public constant DUR_90D = 90 days;
    uint256 public constant DUR_1Y = 365 days;
    uint256 public constant DUR_3Y = 1_095 days;

    uint256 public constant MAX_LOCKS_PER_USER = 50;

    /// @dev Floor under which auto-drip is skipped — avoids paying ~150k extra gas
    ///      per user action just to swap dust through the router.
    uint256 public constant MIN_AUTO_DRIP_PLS = 100 ether;

    /// @dev Precision multiplier for rewardPerToken accumulator. Large enough to
    ///      avoid truncation when reward token has fewer decimals than staking token.
    uint256 internal constant PRECISION = 1e30;

    // ─────────────── Tokens / external ───────────────
    IERC20 public immutable STAKING_TOKEN;        // TSTT (18 dec)
    IERC20 public immutable REWARDS_TOKEN;        // pDAI

    IPulseXRouter public dexRouter;
    /// @notice OMEGA DAO Treasury — receives the 10% EES share as raw PLS (TSTT→WPLS→ETH).
    address public daoTreasury;
    address public devWallet;

    // ─────────────── Reward state (Synthetix) ───────────────
    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public totalOwed;

    // ─────────────── Stake state ───────────────
    uint256 public totalRawStaked;       // sum of flex + all lock principals
    uint256 public totalEffectiveStaked; // sum of weighted positions

    mapping(address => uint256) public flexBalance;            // raw TSTT in flex
    mapping(address => uint256) public userEffective;          // total effective across flex + locks

    struct LockPosition {
        uint128 amount;        // raw TSTT
        uint128 effective;     // amount * mult / 100
        uint64 unlockTime;
        uint32 multiplier;     // 300/500/1000
        bool active;
    }
    mapping(address => LockPosition[]) internal _locks;

    bool public paused;

    // ─────────────── Events ───────────────
    event Staked(address indexed user, uint256 amount, uint256 effective);
    event StakedLocked(address indexed user, uint256 indexed lockId, uint256 amount, uint256 unlockTime, uint256 multiplier);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event Unlocked(address indexed user, uint256 indexed lockId, uint256 returned, uint256 penalty);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event ToppedUp(uint256 plsAmount, uint256 rewardAmount);
    event DaoTreasuryUpdated(address indexed t);
    event DevWalletUpdated(address indexed dev);
    event DexRouterUpdated(address indexed r);
    event Paused(bool isPaused);
    event RewardsDurationUpdated(uint256 d);
    event EESDistributed(
        uint256 penaltyTotal,
        uint256 burned,
        uint256 toDev,
        uint256 primaryDai,
        uint256 secondaryPLS
    );

    // ─────────────── Modifiers ───────────────
    modifier notPaused() {
        if (paused) revert IsPaused();
        _;
    }

    /// @dev Opportunistically drains accumulated PLS (Flux 4.25% tax leg, EES fallback PLS,
    ///      etc.) into a fresh pDAI drip on every state-changing user call. Wrapped in
    ///      try/catch via the self-only `_fallbackPlsToRewards` so a router failure cannot
    ///      brick stakes/withdrawals. Skipped below MIN_AUTO_DRIP_PLS to avoid swapping dust.
    modifier autoDrip() {
        uint256 plsBal = address(this).balance;
        if (plsBal >= MIN_AUTO_DRIP_PLS && address(dexRouter) != address(0)) {
            try this._fallbackPlsToRewards(plsBal) {} catch {}
        }
        _;
    }

    modifier updateReward(address account) {
        uint256 newRPT = rewardPerToken();
        if (newRPT > rewardPerTokenStored && totalEffectiveStaked > 0) {
            totalOwed += ((newRPT - rewardPerTokenStored) * totalEffectiveStaked) / PRECISION;
        }
        rewardPerTokenStored = newRPT;
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ─────────────── Constructor ───────────────
    constructor(
        address _stakingToken,
        address _rewardsToken,
        address _owner,
        address _daoTreasury,
        address _dev,
        address _router
    ) Ownable(_owner) {
        if (_stakingToken == address(0) || _rewardsToken == address(0)) revert ZeroAddress();
        if (_dev == address(0)) revert ZeroAddress();
        STAKING_TOKEN = IERC20(_stakingToken);
        REWARDS_TOKEN = IERC20(_rewardsToken);
        daoTreasury = _daoTreasury; // may be set later via setter
        devWallet = _dev;
        if (_router != address(0)) dexRouter = IPulseXRouter(_router);
    }

    // ─────────────── Tier helpers ───────────────
    function getMultiplierForDuration(uint256 duration) public pure returns (uint256) {
        if (duration == 0) return FLEX_MULT;
        if (duration == DUR_90D) return MULT_90D;
        if (duration == DUR_1Y) return MULT_1Y;
        if (duration == DUR_3Y) return MULT_3Y;
        revert InvalidDuration();
    }

    function getLockTiers() external pure returns (uint256[] memory durations, uint256[] memory mults) {
        durations = new uint256[](4);
        mults = new uint256[](4);
        durations[0] = 0;        mults[0] = FLEX_MULT;
        durations[1] = DUR_90D;  mults[1] = MULT_90D;
        durations[2] = DUR_1Y;   mults[2] = MULT_1Y;
        durations[3] = DUR_3Y;   mults[3] = MULT_3Y;
    }

    // ─────────────── Views ───────────────
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalEffectiveStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalEffectiveStaked;
    }

    function earned(address account) public view returns (uint256) {
        uint256 currentRPT = rewardPerToken();
        return (userEffective[account] * (currentRPT - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function effectiveBalance(address account) external view returns (uint256) {
        return userEffective[account];
    }

    function stakedBalance(address account) external view returns (uint256) {
        return _rawBalance(account);
    }

    function _rawBalance(address account) internal view returns (uint256 raw) {
        raw = flexBalance[account];
        LockPosition[] storage arr = _locks[account];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].active) raw += arr[i].amount;
        }
    }

    function lockCount(address account) external view returns (uint256) {
        return _locks[account].length;
    }

    function getLock(address account, uint256 lockId) external view returns (LockPosition memory) {
        if (lockId >= _locks[account].length) revert LockNotFound();
        return _locks[account][lockId];
    }

    function getUserLocks(address account) external view returns (LockPosition[] memory) {
        return _locks[account];
    }

    // ─────────────── Stake (flex) ───────────────
    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) autoDrip {
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pullStaking(msg.sender, amount);

        uint256 addEff = (received * FLEX_MULT) / 100;
        flexBalance[msg.sender] += received;
        userEffective[msg.sender] += addEff;

        totalRawStaked += received;
        totalEffectiveStaked += addEff;

        emit Staked(msg.sender, received, addEff);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) autoDrip {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = flexBalance[msg.sender];
        if (bal < amount) revert InsufficientFlex();

        // Compute effective change BEFORE mutating raw balance
        uint256 effBefore = (bal * FLEX_MULT) / 100;
        uint256 effAfter = ((bal - amount) * FLEX_MULT) / 100;
        uint256 effDelta = effBefore - effAfter;

        flexBalance[msg.sender] = bal - amount;
        userEffective[msg.sender] -= effDelta;
        totalRawStaked -= amount;
        totalEffectiveStaked -= effDelta;

        uint256 fee = (amount * FLEX_WITHDRAW_FEE_BPS) / BPS;
        if (fee > 0) _processWithdrawFee(fee);
        STAKING_TOKEN.safeTransfer(msg.sender, amount - fee);

        emit Withdrawn(msg.sender, amount, fee);
    }

    // ─────────────── Stake (locked) ───────────────
    function stakeLocked(uint256 amount, uint256 duration) external nonReentrant notPaused updateReward(msg.sender) autoDrip {
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidDuration(); // flex goes through stake()
        uint256 mult = getMultiplierForDuration(duration);

        if (_locks[msg.sender].length >= MAX_LOCKS_PER_USER) revert TooManyLocks();

        uint256 received = _pullStaking(msg.sender, amount);
        uint256 addEff = (received * mult) / 100;

        _locks[msg.sender].push(LockPosition({
            amount: uint128(received),
            effective: uint128(addEff),
            unlockTime: uint64(block.timestamp + duration),
            multiplier: uint32(mult),
            active: true
        }));

        userEffective[msg.sender] += addEff;
        totalRawStaked += received;
        totalEffectiveStaked += addEff;

        emit StakedLocked(msg.sender, _locks[msg.sender].length - 1, received, block.timestamp + duration, mult);
    }

    /// @notice Unlock one or more positions. Pass IDs in DESCENDING order to avoid reorder bugs.
    function unlock(uint256[] calldata lockIds) external nonReentrant updateReward(msg.sender) autoDrip {
        uint256 len = lockIds.length;
        if (len == 0) revert ZeroAmount();

        uint256 totalReturn;
        uint256 totalPenalty;
        uint256 totalExpiredFee;
        uint256 prevId = type(uint256).max;
        LockPosition[] storage arr = _locks[msg.sender];

        for (uint256 i = 0; i < len; i++) {
            uint256 id = lockIds[i];
            if (id >= arr.length) revert LockNotFound();
            if (i > 0 && id >= prevId) revert InvalidLockOrder();
            prevId = id;

            LockPosition storage lp = arr[id];
            if (!lp.active) revert LockNotFound();

            uint256 amt = lp.amount;
            uint256 eff = lp.effective;

            // Decrement aggregates BEFORE external calls
            userEffective[msg.sender] -= eff;
            totalEffectiveStaked -= eff;
            totalRawStaked -= amt;

            lp.active = false;

            uint256 expiredFee = 0;
            if (block.timestamp >= lp.unlockTime) {
                // Expired locks pay the same 1% withdraw fee as flex withdrawals.
                expiredFee = (amt * FLEX_WITHDRAW_FEE_BPS) / BPS;
                totalReturn += amt - expiredFee;
                totalExpiredFee += expiredFee;
                emit Unlocked(msg.sender, id, amt, 0);
            } else {
                uint256 penalty = (amt * EES_BPS) / BPS;
                totalReturn += amt - penalty;
                totalPenalty += penalty;
                emit Unlocked(msg.sender, id, amt, penalty);
            }
        }

        if (totalPenalty > 0) _processEES(totalPenalty);
        if (totalExpiredFee > 0) _processWithdrawFee(totalExpiredFee);
        if (totalReturn > 0) STAKING_TOKEN.safeTransfer(msg.sender, totalReturn);
    }

    // ─────────────── Claim ───────────────
    function getReward() public nonReentrant updateReward(msg.sender) autoDrip {
        uint256 r = rewards[msg.sender];
        if (r == 0) return;
        rewards[msg.sender] = 0;
        totalOwed = totalOwed > r ? totalOwed - r : 0;
        REWARDS_TOKEN.safeTransfer(msg.sender, r);
        emit RewardPaid(msg.sender, r);
    }

    function exit() external {
        if (flexBalance[msg.sender] > 0) withdraw(flexBalance[msg.sender]);
        getReward();
    }

    // ─────────────── Reward injection ───────────────
    function notifyRewardAmount(uint256 reward) external nonReentrant updateReward(address(0)) {
        if (reward == 0) revert NoNewRewards();
        // Pull pDAI from caller
        REWARDS_TOKEN.safeTransferFrom(msg.sender, address(this), reward);
        _notify(reward);
    }

    /// @notice Send PLS to receive a fresh 7-day pDAI drip. Auto-swaps WPLS→pDAI via router.
    function topUp() external payable nonReentrant updateReward(address(0)) {
        if (msg.value == 0) revert ZeroPLS();
        uint256 received = _swapPLSToReward(msg.value);
        if (received == 0) revert SwapYieldedZero();
        _notify(received);
        emit ToppedUp(msg.value, received);
    }

    /// @notice Permissionless drain of any PLS sitting in the vault (e.g. from the Flux tax stream
    ///         on TSTT or from the EES fallback path). Swaps PLS→pDAI and notifies stakers.
    ///         Reverts only if the vault is empty or the swap yields zero.
    function processRewards() external nonReentrant updateReward(address(0)) {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroPLS();
        uint256 received = _swapPLSToReward(bal);
        if (received == 0) revert SwapYieldedZero();
        _notify(received);
        emit ToppedUp(bal, received);
    }

    /// @dev External-call wrapper used by `_processEES` so the inner swap can be safely try/catch'd.
    ///      MUST only be callable by this contract — protects against arbitrary actors poking it
    ///      to bypass the unlock context.
    function _fallbackPlsToRewards(uint256 plsAmount) external {
        if (msg.sender != address(this)) revert ZeroAddress();
        uint256 received = _swapPLSToReward(plsAmount);
        if (received > 0) _notify(received);
    }

    function _notify(uint256 reward) internal {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // Solvency: balance must cover all future drips + accrued totalOwed
        uint256 bal = REWARDS_TOKEN.balanceOf(address(this));
        if (rewardRate > bal / rewardsDuration) revert RewardTooHigh();
        if (bal < totalOwed) revert Insolvent();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // ─────────────── Internal — EES distribution ───────────────
    function _processEES(uint256 penalty) internal {
        uint256 burnAmt   = (penalty * EES_BURN_BPS) / BPS;
        uint256 devAmt    = (penalty * EES_DEV_BPS) / BPS;
        uint256 primary   = (penalty * EES_PRIMARY_BPS) / BPS;
        uint256 secondary = penalty - burnAmt - devAmt - primary; // = 10%

        if (burnAmt > 0) _burnTokens(burnAmt);
        if (devAmt > 0)  STAKING_TOKEN.safeTransfer(devWallet, devAmt);

        uint256 daiPrimary;
        if (primary > 0) {
            if (address(dexRouter) != address(0)) {
                daiPrimary = _swapTSTTToReward(primary);
                if (daiPrimary > 0) {
                    _notify(daiPrimary);
                } else {
                    _burnTokens(primary);
                }
            } else {
                _burnTokens(primary);
            }
        }

        uint256 plsToTreasury;
        if (secondary > 0) {
            if (address(dexRouter) != address(0) && daoTreasury != address(0)) {
                uint256 plsOut = _swapTSTTToPLS(secondary);
                if (plsOut > 0) {
                    (bool ok, ) = daoTreasury.call{value: plsOut}("");
                    if (ok) {
                        plsToTreasury = plsOut;
                    } else {
                        // Treasury rejected PLS — try to route to pDAI rewards instead.
                        // If that swap also fails, leave PLS in vault for processRewards() drain.
                        try this._fallbackPlsToRewards(plsOut) {} catch {}
                    }
                } else {
                    _burnTokens(secondary);
                }
            } else {
                _burnTokens(secondary);
            }
        }

        emit EESDistributed(penalty, burnAmt, devAmt, daiPrimary, plsToTreasury);
    }

    /// @dev Routes a TSTT withdrawal fee: swap TSTT→WPLS→pDAI, notify this vault.
    ///      Falls back to TSTT burn if router unset or swap fails.
    function _processWithdrawFee(uint256 amount) internal {
        if (amount == 0) return;
        if (address(dexRouter) == address(0)) {
            _burnTokens(amount);
            return;
        }
        uint256 daiOut = _swapTSTTToReward(amount);
        if (daiOut == 0) {
            _burnTokens(amount);
            return;
        }
        _notify(daiOut);
    }

    /// @dev Swap TSTT→WPLS→PLS (router unwraps to ETH). Returns PLS received by this contract.
    function _swapTSTTToPLS(uint256 amountIn) internal returns (uint256) {
        if (address(dexRouter) == address(0)) return 0;
        STAKING_TOKEN.forceApprove(address(dexRouter), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(STAKING_TOKEN);
        path[1] = WPLS;

        uint256 balBefore = address(this).balance;
        try dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp
        ) {
            return address(this).balance - balBefore;
        } catch {
            STAKING_TOKEN.forceApprove(address(dexRouter), 0);
            return 0;
        }
    }

    function _swapTSTTToReward(uint256 amountIn) internal returns (uint256) {
        if (address(dexRouter) == address(0)) revert NoRouter();
        STAKING_TOKEN.forceApprove(address(dexRouter), amountIn);
        address[] memory path = new address[](3);
        path[0] = address(STAKING_TOKEN);
        path[1] = WPLS;
        path[2] = address(REWARDS_TOKEN);

        uint256 balBefore = REWARDS_TOKEN.balanceOf(address(this));
        try dexRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp
        ) {
            return REWARDS_TOKEN.balanceOf(address(this)) - balBefore;
        } catch {
            STAKING_TOKEN.forceApprove(address(dexRouter), 0);
            return 0;
        }
    }

    function _swapPLSToReward(uint256 plsIn) internal returns (uint256) {
        if (address(dexRouter) == address(0)) revert NoRouter();
        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(REWARDS_TOKEN);

        uint256 balBefore = REWARDS_TOKEN.balanceOf(address(this));
        dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: plsIn}(
            0, path, address(this), block.timestamp
        );
        return REWARDS_TOKEN.balanceOf(address(this)) - balBefore;
    }

    // ─────────────── Internal — token plumbing ───────────────
    function _pullStaking(address from, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = STAKING_TOKEN.balanceOf(address(this));
        STAKING_TOKEN.safeTransferFrom(from, address(this), amount);
        received = STAKING_TOKEN.balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();
    }

    function _burnTokens(uint256 amount) internal {
        (bool ok, ) = address(STAKING_TOKEN).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        if (!ok) {
            STAKING_TOKEN.safeTransfer(DEAD, amount);
        }
    }

    // ─────────────── Admin ───────────────
    function setDaoTreasury(address t) external onlyOwner {
        daoTreasury = t;
        emit DaoTreasuryUpdated(t);
    }

    function setDexRouter(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        dexRouter = IPulseXRouter(r);
        emit DexRouterUpdated(r);
    }

    function setDevWallet(address d) external onlyOwner {
        if (d == address(0)) revert ZeroAddress();
        devWallet = d;
        emit DevWalletUpdated(d);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    function setRewardsDuration(uint256 d) external onlyOwner {
        if (d == 0) revert ZeroDuration();
        if (block.timestamp <= periodFinish) revert PeriodNotFinished();
        rewardsDuration = d;
        emit RewardsDurationUpdated(d);
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        if (token == address(STAKING_TOKEN)) revert CannotRecoverStaking();
        if (token == address(REWARDS_TOKEN)) revert CannotRecoverReward();
        IERC20(token).safeTransfer(owner(), amount);
    }

    receive() external payable {}
}
