// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IMintableERC20, IFarmTokenMinter} from "./interfaces/IMintableERC20.sol";
import {IExternalChef} from "./interfaces/IExternalChef.sol";
import {IPulseXRouter, IUniswapV2Pair} from "./interfaces/IPulseXRouter.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

/// @title CabalEmissions
/// @notice Multi-pool LP farm. On every pool update mints `rewardsPerSec` × elapsed × allocShare:
///           - `devPercent` to `devAddress`     (default 5%)
///           - `feePercent` to `feeAddress`     (default 5%)
///           - remainder to stakers (split by accTokensPerShare)
///           - additional `referralRate` minted on top, paid to a user's locked referrer on harvest.
///         Per-pool deposit/withdraw fees in LP units → broken to PLS and topUp()'d into the
///         tieredVault (TieredStakingVault), with a fallback transfer to feeAddress on failure.
///         Optional PulseX pass-through: LP forwarded into the underlying chef, harvested INC
///         swept by swapping INC→WPLS→PLS and topUp()'d into tieredVault, with a fallback
///         raw INC transfer to `rehypDestination` on failure.
contract CabalEmissions is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ─────────────── Errors ───────────────
    error ZeroAddress();
    error InvalidPercent();
    error InvalidFeeBP();
    error PoolDuplicate();
    error PoolOutOfRange();
    error AmountTooLow();
    error InvalidExternalFarm();
    error NotExternalFarm();
    error TooHighReferral();
    error TooHighRewardRate();
    error CannotRecoverLp();
    error CannotRecoverReward();

    // ─────────────── Constants ───────────────
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DEV_PERCENT = 1_000;
    uint256 public constant MAX_FEE_PERCENT = 1_000;
    uint256 public constant MAX_POOL_FEE_BP = 400;
    uint256 public constant MAX_REWARDS_PER_SEC = 25 ether;
    uint256 public constant MAX_REFERRAL_RATE = 500;

    // ─────────────── External (PulseX) ───────────────
    address public immutable INC_TOKEN;
    address public immutable PULSEX_MC;
    address public rehypDestination;

    // ─────────────── Reward ───────────────
    IMintableERC20 public immutable rewardToken;

    address public devAddress;
    address public feeAddress;
    uint256 public devPercent;
    uint256 public feePercent;

    uint256 public rewardsPerSec;
    uint256 public startTime;

    // ─────────────── Referral ───────────────
    uint256 public referralRate = 500;
    mapping(address => address) public referral;
    mapping(address => uint256) public referralEarned;
    address public defaultReferrer;

    // ─────────────── PLS routing ───────────────
    address public router;
    address public WPLS;
    address public tieredVault;

    // ─────────────── Pools ───────────────
    enum ExternalProtocol { NONE, PULSEX }

    struct PoolInfo {
        IERC20 token;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint16 depositFeeBP;
        uint16 withdrawFeeBP;
        uint256 accTokensPerShare;
        bool isStarted;
        ExternalProtocol externalProtocol;
        uint256 externalPid;
        uint256 lpBalance;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolView {
        uint256 pid;
        address token;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint16 depositFeeBP;
        uint16 withdrawFeeBP;
        uint256 accTokensPerShare;
        bool isStarted;
        ExternalProtocol externalProtocol;
        uint256 externalPid;
        uint256 lpBalance;
        uint256 rewardsPerSecond;
    }

    struct UserView {
        uint256 pid;
        uint256 stakedAmount;
        uint256 unclaimedRewards;
        uint256 lpBalance;
        uint256 allowance;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => bool) public lpAdded;

    uint256 public totalAllocPoint;

    // ─────────────── Events ───────────────
    event PoolAdded(uint256 indexed pid, address indexed lp, uint256 allocPoint, uint16 depositFeeBP, uint16 withdrawFeeBP);
    event PoolSet(uint256 indexed pid, uint256 allocPoint);
    event PoolFeeSet(uint256 indexed pid, uint16 depositFeeBP, uint16 withdrawFeeBP);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event ReferralPaid(address indexed referrer, address indexed user, uint256 amount);
    event DevAddressUpdated(address indexed dev);
    event FeeAddressUpdated(address indexed fee);
    event DevPercentUpdated(uint256 percent);
    event FeePercentUpdated(uint256 percent);
    event RewardsPerSecUpdated(uint256 rate);
    event RehypDestinationUpdated(address indexed dest);
    event IncSwept(uint256 amount, address indexed to);
    event LpFeeProcessed(address indexed lp, uint256 lpAmount, uint256 plsTopUp, bool success);
    event ExternalFarmCleared(uint256 indexed pid);
    event RewardMinterTransferred(address indexed newMinter);
    event SetTieredVault(address indexed vault);
    event SetRouter(address indexed router);
    event SetReferralRate(uint256 rate);
    event SetDefaultReferrer(address indexed referrer);

    struct InitParams {
        address rewardToken;
        address devAddress;
        address feeAddress;
        uint256 devPercent;
        uint256 feePercent;
        uint256 rewardsPerSec;
        uint256 startTime;
        address pulseXMC;
        address incToken;
        address rehypDestination;
        address router;
        address tieredVault;
        address defaultReferrer;
        address owner;
    }

    constructor(InitParams memory p) Ownable(p.owner) {
        if (p.rewardToken == address(0)) revert ZeroAddress();
        if (p.devAddress == address(0) || p.feeAddress == address(0)) revert ZeroAddress();
        if (p.defaultReferrer == address(0)) revert ZeroAddress();
        if (p.devPercent > MAX_DEV_PERCENT || p.feePercent > MAX_FEE_PERCENT) revert InvalidPercent();
        if (p.rewardsPerSec > MAX_REWARDS_PER_SEC) revert TooHighRewardRate();

        rewardToken = IMintableERC20(p.rewardToken);
        devAddress = p.devAddress;
        feeAddress = p.feeAddress;
        devPercent = p.devPercent;
        feePercent = p.feePercent;
        rewardsPerSec = p.rewardsPerSec;
        startTime = p.startTime == 0 ? block.timestamp : p.startTime;

        PULSEX_MC = p.pulseXMC;
        INC_TOKEN = p.incToken;
        rehypDestination = p.rehypDestination == address(0) ? p.devAddress : p.rehypDestination;

        defaultReferrer = p.defaultReferrer;
        tieredVault = p.tieredVault;
        _initRouter(p.router);
    }

    function _initRouter(address _router) private {
        router = _router;
        if (_router != address(0)) {
            try IPulseXRouter(_router).WPLS() returns (address w) {
                WPLS = w;
            } catch {}
        }
    }

    receive() external payable {}

    // ─────────────── Pools ───────────────
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(
        IERC20 _token,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint16 _withdrawFeeBP,
        ExternalProtocol _externalProtocol,
        uint256 _externalPid,
        bool _withUpdate
    ) external onlyOwner {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (lpAdded[address(_token)]) revert PoolDuplicate();
        if (_depositFeeBP > MAX_POOL_FEE_BP || _withdrawFeeBP > MAX_POOL_FEE_BP) revert InvalidFeeBP();

        if (_withUpdate) massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        bool _isStarted = block.timestamp >= startTime;

        poolInfo.push(PoolInfo({
            token: _token,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            depositFeeBP: _depositFeeBP,
            withdrawFeeBP: _withdrawFeeBP,
            accTokensPerShare: 0,
            isStarted: _isStarted,
            externalProtocol: _externalProtocol,
            externalPid: _externalPid,
            lpBalance: 0
        }));

        if (_isStarted) totalAllocPoint += _allocPoint;
        lpAdded[address(_token)] = true;

        emit PoolAdded(poolInfo.length - 1, address(_token), _allocPoint, _depositFeeBP, _withdrawFeeBP);
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        if (_withUpdate) massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        }
        pool.allocPoint = _allocPoint;
        emit PoolSet(_pid, _allocPoint);
    }

    function setPoolFees(uint256 _pid, uint16 _depositFeeBP, uint16 _withdrawFeeBP) external onlyOwner {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        if (_depositFeeBP > MAX_POOL_FEE_BP || _withdrawFeeBP > MAX_POOL_FEE_BP) revert InvalidFeeBP();
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].withdrawFeeBP = _withdrawFeeBP;
        emit PoolFeeSet(_pid, _depositFeeBP, _withdrawFeeBP);
    }

    // ─────────────── Reward views ───────────────
    function _multiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= startTime) return 0;
        if (_from < startTime) return _to - startTime;
        return _to - _from;
    }

    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        if (_pid >= poolInfo.length) return 0;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 acc = pool.accTokensPerShare;
        uint256 supply = pool.lpBalance;
        if (block.timestamp > pool.lastRewardTime && supply > 0 && totalAllocPoint > 0) {
            uint256 mul = _multiplier(pool.lastRewardTime, block.timestamp);
            uint256 lpPercent = BPS - devPercent - feePercent;
            uint256 reward = (mul * rewardsPerSec * pool.allocPoint * lpPercent) / (totalAllocPoint * BPS);
            acc += (reward * 1e18) / supply;
        }
        return (user.amount * acc) / 1e18 - user.rewardDebt;
    }

    function massUpdatePools() public {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            updatePool(i);
        }
    }

    function updatePool(uint256 _pid) public {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];

        if (block.timestamp <= pool.lastRewardTime) return;
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint += pool.allocPoint;
        }
        uint256 supply = pool.lpBalance;
        if (supply == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 mul = _multiplier(pool.lastRewardTime, block.timestamp);
        uint256 generated = mul * rewardsPerSec;
        uint256 poolReward = (generated * pool.allocPoint) / totalAllocPoint;

        uint256 lpPercent = BPS - devPercent - feePercent;

        if (devPercent > 0) {
            rewardToken.mint(devAddress, (poolReward * devPercent) / BPS);
        }
        if (feePercent > 0) {
            rewardToken.mint(feeAddress, (poolReward * feePercent) / BPS);
        }
        // lp share + referral pool (mirrors EMIT: referrals are paid out of held balance,
        // funded by an extra mint on top of the LP share).
        uint256 lpMint = (poolReward * lpPercent) / BPS;
        uint256 refMint = (poolReward * referralRate) / BPS;
        uint256 selfMint = lpMint + refMint;
        if (selfMint > 0) {
            rewardToken.mint(address(this), selfMint);
        }

        pool.accTokensPerShare += (lpMint * 1e18) / supply;
        pool.lastRewardTime = block.timestamp;
    }

    // ─────────────── Stake / Unstake ───────────────
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        _deposit(_pid, _amount, _referrer, msg.sender);
    }

    function depositOnBehalfOf(
        uint256 _pid,
        uint256 _amount,
        address _referrer,
        address _staker
    ) external nonReentrant {
        if (_staker == address(0)) revert ZeroAddress();
        _deposit(_pid, _amount, _referrer, _staker);
    }

    function _lockReferrer(address _staker, address _referrer) private returns (address ref) {
        ref = referral[_staker];
        if (ref == address(0)) {
            if (_referrer != address(0) && _referrer != _staker && _referrer != address(this)) {
                ref = _referrer;
            } else {
                ref = defaultReferrer;
            }
            referral[_staker] = ref;
        }
    }

    function _payReward(address _staker, address _ref, uint256 _pending) private {
        if (_pending == 0) return;
        uint256 referralAmount = (_pending * referralRate) / BPS;
        if (referralAmount > 0 && _ref != address(0)) {
            referralEarned[_ref] += referralAmount;
            _safeRewardTransfer(_ref, referralAmount);
            emit ReferralPaid(_ref, _staker, referralAmount);
        }
        _safeRewardTransfer(_staker, _pending);
        emit RewardPaid(_staker, _pending);
    }

    function _deposit(uint256 _pid, uint256 _amount, address _referrer, address _staker) private {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_staker];

        _lockReferrer(_staker, _referrer);

        updatePool(_pid);
        _settlePending(pool, user, _staker);

        if (_amount > 0) {
            uint256 balBefore = pool.token.balanceOf(address(this));
            pool.token.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 received = pool.token.balanceOf(address(this)) - balBefore;
            if (received == 0) revert AmountTooLow();

            uint256 credited = received;
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (received * pool.depositFeeBP) / BPS;
                if (depositFee > 0) {
                    _processLpFee(pool.token, depositFee);
                    credited -= depositFee;
                }
            }

            user.amount += credited;
            pool.lpBalance += credited;

            _externalDepositLp(pool, credited);
        }

        user.rewardDebt = (user.amount * pool.accTokensPerShare) / 1e18;
        emit Deposit(_staker, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount < _amount) revert AmountTooLow();

        updatePool(_pid);
        _settlePending(pool, user, msg.sender);

        if (_amount > 0) {
            user.amount -= _amount;
            pool.lpBalance -= _amount;

            _externalWithdrawLp(pool, _amount);

            uint256 toUser = _amount;
            if (pool.withdrawFeeBP > 0) {
                uint256 withdrawFee = (_amount * pool.withdrawFeeBP) / BPS;
                if (withdrawFee > 0) {
                    _processLpFee(pool.token, withdrawFee);
                    toUser -= withdrawFee;
                }
            }
            pool.token.safeTransfer(msg.sender, toUser);
        }

        user.rewardDebt = (user.amount * pool.accTokensPerShare) / 1e18;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _externalChefHarvest(pool);
        _sweepInc();

        updatePool(_pid);
        _settlePending(pool, user, msg.sender);
        user.rewardDebt = (user.amount * pool.accTokensPerShare) / 1e18;
    }

    /// @notice Mass-harvest pending TSTT (and pull/sweep INC from any PULSEX pass-through pools)
    ///         across every pool in one call. Sweeps INC once at the end to amortise gas.
    function harvestAll() external nonReentrant {
        uint256 n = poolInfo.length;
        for (uint256 i = 0; i < n; i++) {
            PoolInfo storage pool = poolInfo[i];
            UserInfo storage user = userInfo[i][msg.sender];

            _externalChefHarvest(pool);

            updatePool(i);
            _settlePending(pool, user, msg.sender);
            user.rewardDebt = (user.amount * pool.accTokensPerShare) / 1e18;
        }
        _sweepInc();
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) revert AmountTooLow();

        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpBalance -= amount;

        if (pool.externalProtocol == ExternalProtocol.PULSEX && PULSEX_MC != address(0)) {
            try IExternalChef(PULSEX_MC).withdraw(pool.externalPid, amount) {
                _sweepInc();
            } catch {
                try IExternalChef(PULSEX_MC).emergencyWithdraw(pool.externalPid) {
                    _sweepInc();
                } catch {}
            }
        }

        pool.token.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // ─────────────── INC rehyp → tieredVault ───────────────
    function sweepInc() external {
        _sweepInc();
    }

    function _sweepInc() internal {
        if (INC_TOKEN == address(0)) return;
        uint256 bal = IERC20(INC_TOKEN).balanceOf(address(this));
        if (bal == 0) return;

        if (router != address(0) && WPLS != address(0) && tieredVault != address(0)) {
            try this._swapAndTopUpInc(bal) {
                emit IncSwept(bal, tieredVault);
                return;
            } catch {}
        }

        if (rehypDestination != address(0)) {
            IERC20(INC_TOKEN).safeTransfer(rehypDestination, bal);
            emit IncSwept(bal, rehypDestination);
        }
    }

    /// @dev External so we can wrap the body in a try/catch for atomic rollback on swap failure.
    function _swapAndTopUpInc(uint256 amount) external {
        if (msg.sender != address(this)) revert ZeroAddress();
        uint256 plsBefore = address(this).balance;

        IERC20(INC_TOKEN).forceApprove(router, amount);
        address[] memory path = new address[](2);
        path[0] = INC_TOKEN;
        path[1] = WPLS;
        IPulseXRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );

        uint256 plsOut = address(this).balance - plsBefore;
        if (plsOut == 0) revert AmountTooLow();
        IStakingVault(tieredVault).topUp{value: plsOut}();
    }

    function harvestExternal(uint256[] calldata _pids) external onlyOwner {
        if (PULSEX_MC == address(0)) return;
        for (uint256 i = 0; i < _pids.length; i++) {
            if (_pids[i] >= poolInfo.length) revert PoolOutOfRange();
            _externalChefHarvest(poolInfo[_pids[i]]);
        }
        _sweepInc();
    }

    function clearExternalFarm(uint256 _pid) external onlyOwner nonReentrant {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.externalProtocol == ExternalProtocol.NONE) revert NotExternalFarm();
        if (PULSEX_MC == address(0)) revert NotExternalFarm();

        IExternalChef(PULSEX_MC).emergencyWithdraw(pool.externalPid);
        _sweepInc();
        pool.externalProtocol = ExternalProtocol.NONE;
        emit ExternalFarmCleared(_pid);
    }

    // ─────────────── LP fee → PLS → tieredVault ───────────────
    function _processLpFee(IERC20 lp, uint256 amount) internal {
        if (amount == 0) return;

        if (router == address(0) || tieredVault == address(0) || WPLS == address(0)) {
            lp.safeTransfer(feeAddress, amount);
            emit LpFeeProcessed(address(lp), amount, 0, false);
            return;
        }

        try this._breakLpAndTopUp(lp, amount) returns (uint256 plsTotal) {
            emit LpFeeProcessed(address(lp), amount, plsTotal, true);
        } catch {
            lp.safeTransfer(feeAddress, amount);
            emit LpFeeProcessed(address(lp), amount, 0, false);
        }
    }

    function _breakLpAndTopUp(IERC20 lp, uint256 amount) external returns (uint256 plsTotal) {
        if (msg.sender != address(this)) revert ZeroAddress();

        address t0 = IUniswapV2Pair(address(lp)).token0();
        address t1 = IUniswapV2Pair(address(lp)).token1();

        IERC20(address(lp)).forceApprove(router, amount);

        uint256 plsBefore = address(this).balance;

        if (t0 == WPLS || t1 == WPLS) {
            address other = t0 == WPLS ? t1 : t0;
            IPulseXRouter(router).removeLiquidityETHSupportingFeeOnTransferTokens(
                other, amount, 0, 0, address(this), block.timestamp
            );
            uint256 otherBal = IERC20(other).balanceOf(address(this));
            if (otherBal > 0) {
                _swapTokenToPLS(other, otherBal);
            }
        } else {
            IPulseXRouter(router).removeLiquidity(
                t0, t1, amount, 0, 0, address(this), block.timestamp
            );
            uint256 b0 = IERC20(t0).balanceOf(address(this));
            uint256 b1 = IERC20(t1).balanceOf(address(this));
            if (b0 > 0) _swapTokenToPLS(t0, b0);
            if (b1 > 0) _swapTokenToPLS(t1, b1);
        }

        plsTotal = address(this).balance - plsBefore;
        if (plsTotal == 0) revert AmountTooLow();
        IStakingVault(tieredVault).topUp{value: plsTotal}();
    }

    function _swapTokenToPLS(address token, uint256 amount) internal {
        IERC20(token).forceApprove(router, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WPLS;
        IPulseXRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );
    }

    // ─────────────── Internal helpers ───────────────
    function _safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 bal = IERC20(address(rewardToken)).balanceOf(address(this));
        uint256 toSend = _amount > bal ? bal : _amount;
        if (toSend > 0) {
            IERC20(address(rewardToken)).safeTransfer(_to, toSend);
        }
    }

    /// @dev Harvest-only PXMC call (zero-amount deposit triggers PXMC payout). Caller must
    ///      `_sweepInc()` after — kept separate so batched harvests sweep once at the end.
    function _externalChefHarvest(PoolInfo storage pool) internal {
        if (pool.externalProtocol == ExternalProtocol.PULSEX && PULSEX_MC != address(0)) {
            IExternalChef(PULSEX_MC).deposit(pool.externalPid, 0);
        }
    }

    /// @dev Forward LP into PXMC and sweep any INC released by the deposit.
    function _externalDepositLp(PoolInfo storage pool, uint256 amount) internal {
        if (pool.externalProtocol == ExternalProtocol.PULSEX && PULSEX_MC != address(0)) {
            pool.token.forceApprove(PULSEX_MC, amount);
            IExternalChef(PULSEX_MC).deposit(pool.externalPid, amount);
            _sweepInc();
        }
    }

    /// @dev Pull LP back from PXMC and sweep any INC released by the withdraw.
    function _externalWithdrawLp(PoolInfo storage pool, uint256 amount) internal {
        if (pool.externalProtocol == ExternalProtocol.PULSEX && PULSEX_MC != address(0)) {
            IExternalChef(PULSEX_MC).withdraw(pool.externalPid, amount);
            _sweepInc();
        }
    }

    /// @dev Settle the staker's accrued internal rewards (TSTT + referral). Caller is responsible
    ///      for refreshing `user.rewardDebt` after any subsequent change to `user.amount`.
    function _settlePending(PoolInfo storage pool, UserInfo storage user, address _staker) internal {
        if (user.amount == 0) return;
        uint256 pending = (user.amount * pool.accTokensPerShare) / 1e18 - user.rewardDebt;
        _payReward(_staker, referral[_staker], pending);
    }

    // ─────────────── Admin setters ───────────────
    function setDevAddress(address _dev) external onlyOwner {
        if (_dev == address(0)) revert ZeroAddress();
        devAddress = _dev;
        emit DevAddressUpdated(_dev);
    }

    function setFeeAddress(address _fee) external onlyOwner {
        if (_fee == address(0)) revert ZeroAddress();
        feeAddress = _fee;
        emit FeeAddressUpdated(_fee);
    }

    function setDevPercent(uint256 _pct) external onlyOwner {
        if (_pct > MAX_DEV_PERCENT) revert InvalidPercent();
        massUpdatePools();
        devPercent = _pct;
        emit DevPercentUpdated(_pct);
    }

    function setFeePercent(uint256 _pct) external onlyOwner {
        if (_pct > MAX_FEE_PERCENT) revert InvalidPercent();
        massUpdatePools();
        feePercent = _pct;
        emit FeePercentUpdated(_pct);
    }

    function setRewardsPerSec(uint256 _rate) external onlyOwner {
        if (_rate > MAX_REWARDS_PER_SEC) revert TooHighRewardRate();
        massUpdatePools();
        rewardsPerSec = _rate;
        emit RewardsPerSecUpdated(_rate);
    }

    function setRehypDestination(address _dest) external onlyOwner {
        if (_dest == address(0)) revert ZeroAddress();
        rehypDestination = _dest;
        emit RehypDestinationUpdated(_dest);
    }

    function setTieredVault(address _vault) external onlyOwner {
        tieredVault = _vault;
        emit SetTieredVault(_vault);
    }

    function setRouter(address _router) external onlyOwner {
        _initRouter(_router);
        emit SetRouter(_router);
    }

    function setReferralRate(uint256 _rate) external onlyOwner {
        if (_rate > MAX_REFERRAL_RATE) revert TooHighReferral();
        massUpdatePools();
        referralRate = _rate;
        emit SetReferralRate(_rate);
    }

    function setDefaultReferrer(address _ref) external onlyOwner {
        if (_ref == address(0)) revert ZeroAddress();
        defaultReferrer = _ref;
        emit SetDefaultReferrer(_ref);
    }

    function transferRewardMinter(address newMinter) external onlyOwner {
        IFarmTokenMinter(address(rewardToken)).setMinter(newMinter);
        emit RewardMinterTransferred(newMinter);
    }

    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(rewardToken)) revert CannotRecoverReward();
        if (lpAdded[_token]) revert CannotRecoverLp();
        IERC20(_token).safeTransfer(owner(), _amount);
    }

    // ─────────────── Views ───────────────
    function getPoolView(uint256 _pid) public view returns (PoolView memory) {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo memory pool = poolInfo[_pid];
        uint256 lpPercent = BPS - devPercent - feePercent;
        uint256 rps = totalAllocPoint == 0
            ? 0
            : (rewardsPerSec * pool.allocPoint * lpPercent) / (totalAllocPoint * BPS);
        return PoolView({
            pid: _pid,
            token: address(pool.token),
            allocPoint: pool.allocPoint,
            lastRewardTime: pool.lastRewardTime,
            depositFeeBP: pool.depositFeeBP,
            withdrawFeeBP: pool.withdrawFeeBP,
            accTokensPerShare: pool.accTokensPerShare,
            isStarted: pool.isStarted,
            externalProtocol: pool.externalProtocol,
            externalPid: pool.externalPid,
            lpBalance: pool.lpBalance,
            rewardsPerSecond: rps
        });
    }

    function getAllPoolViews() external view returns (PoolView[] memory views) {
        uint256 n = poolInfo.length;
        views = new PoolView[](n);
        for (uint256 i = 0; i < n; i++) views[i] = getPoolView(i);
    }

    function getUserView(uint256 _pid, address _account) public view returns (UserView memory) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_account];
        return UserView({
            pid: _pid,
            stakedAmount: user.amount,
            unclaimedRewards: pendingReward(_pid, _account),
            lpBalance: pool.token.balanceOf(_account),
            allowance: pool.token.allowance(_account, address(this))
        });
    }

    function getUserViews(address _account) external view returns (UserView[] memory views) {
        uint256 n = poolInfo.length;
        views = new UserView[](n);
        for (uint256 i = 0; i < n; i++) views[i] = getUserView(i, _account);
    }
}
