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

/// @title CabalEmissions V4
/// @notice V4 changes vs V3:
///         - Auto-wire: `add()` scans the current PulseX MC for a matching pool and wires
///           pass-through automatically. `addManual()` is the explicit escape hatch.
///         - PULSEX_MC and routers are mutable so the chef can re-target a fresh PulseX MC
///           or fall over to a V1 router if V2 is degraded.
///         - Global `externalEnabled` kill switch — when off, every pool runs as if NONE.
///         - `setExternalFarm(pid, …)` lets the owner re-wire / clear a single pool live.
///         - Multi-user safe `emergencyWithdraw`: if the underlying PulseX call dumps every
///           sibling's LP back into the chef, that pool is auto-cleared to NONE so future
///           sibling withdrawals come straight from chef-local balance.
///         - INC sweep falls back V2 → V1 → leave-in-contract (recoverable by the owner).
///         - LP-fee processor falls back V2 → V1 → raw LP to feeAddress.
contract CabalEmissionsV4 is ReentrancyGuard, Ownable {
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
    error ManualPidMismatch();

    // ─────────────── Constants ───────────────
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DEV_PERCENT = 1_000;
    uint256 public constant MAX_FEE_PERCENT = 1_000;
    uint256 public constant MAX_POOL_FEE_BP = 400;
    uint256 public constant MAX_REWARDS_PER_SEC = 25 ether;
    uint256 public constant MAX_REFERRAL_RATE = 500;
    uint256 public constant MAX_PULSEX_SCAN = 256;

    // ─────────────── External (PulseX) ───────────────
    address public immutable INC_TOKEN;
    address public PULSEX_MC;
    bool public externalEnabled = true;

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
    address public routerV1;
    address public WPLS_V1;
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
    event PoolAdded(uint256 indexed pid, address indexed token, uint256 allocPoint, uint16 depositFeeBP, uint16 withdrawFeeBP);
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
    event IncSwept(uint256 amount, address indexed to);
    event IncSweepFailed(uint256 amount);
    event LpFeeProcessed(address indexed lp, uint256 lpAmount, uint256 plsTopUp, bool success);
    event ExternalFarmSet(uint256 indexed pid, ExternalProtocol protocol, uint256 externalPid);
    event ExternalFarmCleared(uint256 indexed pid);
    event RewardMinterTransferred(address indexed newMinter);
    event SetTieredVault(address indexed vault);
    event SetRouter(address indexed router);
    event SetRouterV1(address indexed router);
    event SetPulseXMC(address indexed mc);
    event SetExternalEnabled(bool enabled);
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
        address router;
        address routerV1;
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

        defaultReferrer = p.defaultReferrer;
        tieredVault = p.tieredVault;
        _initRouter(p.router, false);
        _initRouter(p.routerV1, true);
    }

    function _initRouter(address _router, bool _isV1) private {
        address wpls;
        if (_router != address(0)) {
            try IPulseXRouter(_router).WPLS() returns (address w) { wpls = w; } catch {}
        }
        if (_isV1) {
            routerV1 = _router;
            WPLS_V1 = wpls;
        } else {
            router = _router;
            WPLS = wpls;
        }
    }

    receive() external payable {}

    // ─────────────── Pools ───────────────
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice Auto-wire add: scans the current PulseX MC for a matching pool. If no match
    ///         found, the pool is created as NONE (chef-only).
    function add(
        IERC20 _token,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint16 _withdrawFeeBP,
        bool _withUpdate
    ) external onlyOwner {
        (bool found, uint256 ppid) = _findPulseXPid(address(_token));
        ExternalProtocol proto = found ? ExternalProtocol.PULSEX : ExternalProtocol.NONE;
        _addPool(_token, _allocPoint, _depositFeeBP, _withdrawFeeBP, proto, ppid, _withUpdate);
    }

    /// @notice Manual escape hatch when auto-discovery is wrong (eg PulseX MC pre-registered
    ///         but we want NONE, or PulseX MC migrating mid-flight). If protocol == PULSEX,
    ///         the externalPid is validated against the live PulseX MC.
    function addManual(
        IERC20 _token,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint16 _withdrawFeeBP,
        ExternalProtocol _externalProtocol,
        uint256 _externalPid,
        bool _withUpdate
    ) external onlyOwner {
        if (_externalProtocol == ExternalProtocol.PULSEX) {
            _validatePulseXMatch(address(_token), _externalPid);
        }
        _addPool(_token, _allocPoint, _depositFeeBP, _withdrawFeeBP, _externalProtocol, _externalPid, _withUpdate);
    }

    function _addPool(
        IERC20 _token,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint16 _withdrawFeeBP,
        ExternalProtocol _externalProtocol,
        uint256 _externalPid,
        bool _withUpdate
    ) private {
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

        uint256 pid = poolInfo.length - 1;
        emit PoolAdded(pid, address(_token), _allocPoint, _depositFeeBP, _withdrawFeeBP);
        if (_externalProtocol != ExternalProtocol.NONE) {
            emit ExternalFarmSet(pid, _externalProtocol, _externalPid);
        }
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

    /// @notice Re-wire (or clear) a pool's external pass-through. If protocol == PULSEX,
    ///         the externalPid is validated against the live PulseX MC. Set protocol == NONE
    ///         to disconnect a pool (eg after PulseX migration). The owner is expected to
    ///         pull existing LP back via emergency calls before re-pointing to a different pool.
    function setExternalFarm(
        uint256 _pid,
        ExternalProtocol _externalProtocol,
        uint256 _externalPid
    ) external onlyOwner {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];

        if (_externalProtocol == ExternalProtocol.PULSEX) {
            _validatePulseXMatch(address(pool.token), _externalPid);
        }

        pool.externalProtocol = _externalProtocol;
        pool.externalPid = _externalPid;
        emit ExternalFarmSet(_pid, _externalProtocol, _externalPid);
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

    function harvestAll() external nonReentrant {
        bool anyExternal;
        uint256 n = poolInfo.length;
        for (uint256 i = 0; i < n; i++) {
            UserInfo storage user = userInfo[i][msg.sender];
            if (user.amount == 0) continue;
            PoolInfo storage pool = poolInfo[i];

            if (_externalActive(pool)) {
                IExternalChef(PULSEX_MC).deposit(pool.externalPid, 0);
                anyExternal = true;
            }

            updatePool(i);
            _settlePending(pool, user, msg.sender);
            user.rewardDebt = (user.amount * pool.accTokensPerShare) / 1e18;
        }
        if (anyExternal) _sweepInc();
    }

    /// @notice Multi-user-safe emergency exit. Path:
    ///         1) Try `external.withdraw(user_amount)` — only yanks the caller's share.
    ///         2) On failure try `external.emergencyWithdraw()` which dumps the *entire* pool
    ///            back to the chef. Auto-clear the pool's externalProtocol so sibling
    ///            withdrawals come from chef-local balance instead of trying PulseX again.
    ///         3) On both failures, fall through to the chef-local transfer (will revert if
    ///            chef has no LP, which is the user's only recourse to learn the chef is empty).
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        if (_pid >= poolInfo.length) revert PoolOutOfRange();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) revert AmountTooLow();

        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpBalance -= amount;

        if (_externalActive(pool)) {
            try IExternalChef(PULSEX_MC).withdraw(pool.externalPid, amount) {
                _sweepInc();
            } catch {
                try IExternalChef(PULSEX_MC).emergencyWithdraw(pool.externalPid) {
                    _sweepInc();
                    pool.externalProtocol = ExternalProtocol.NONE;
                    emit ExternalFarmCleared(_pid);
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
        if (tieredVault == address(0)) return;

        if (router != address(0) && WPLS != address(0)) {
            try this._swapAndTopUpInc(router, WPLS, bal) {
                emit IncSwept(bal, tieredVault);
                return;
            } catch {}
        }
        if (routerV1 != address(0) && WPLS_V1 != address(0)) {
            try this._swapAndTopUpInc(routerV1, WPLS_V1, bal) {
                emit IncSwept(bal, tieredVault);
                return;
            } catch {}
        }

        emit IncSweepFailed(bal);
    }

    /// @dev External so we can wrap the body in a try/catch for atomic rollback on swap failure.
    function _swapAndTopUpInc(address _router, address _wpls, uint256 amount) external {
        if (msg.sender != address(this)) revert ZeroAddress();
        uint256 plsBefore = address(this).balance;

        IERC20(INC_TOKEN).forceApprove(_router, amount);
        address[] memory path = new address[](2);
        path[0] = INC_TOKEN;
        path[1] = _wpls;
        IPulseXRouter(_router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );

        uint256 plsOut = address(this).balance - plsBefore;
        if (plsOut == 0) revert AmountTooLow();
        IStakingVault(tieredVault).topUp{value: plsOut}();
    }

    function harvestExternal(uint256[] calldata _pids) external onlyOwner {
        if (!externalEnabled || PULSEX_MC == address(0)) return;
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

        try IExternalChef(PULSEX_MC).emergencyWithdraw(pool.externalPid) {
            _sweepInc();
        } catch {}
        pool.externalProtocol = ExternalProtocol.NONE;
        emit ExternalFarmCleared(_pid);
    }

    // ─────────────── LP fee → PLS → tieredVault ───────────────
    function _processLpFee(IERC20 lp, uint256 amount) internal {
        if (amount == 0) return;
        if (tieredVault == address(0)) {
            lp.safeTransfer(feeAddress, amount);
            emit LpFeeProcessed(address(lp), amount, 0, false);
            return;
        }

        if (router != address(0) && WPLS != address(0)) {
            try this._breakLpAndTopUp(router, WPLS, lp, amount) returns (uint256 plsTotal) {
                emit LpFeeProcessed(address(lp), amount, plsTotal, true);
                return;
            } catch {}
        }
        if (routerV1 != address(0) && WPLS_V1 != address(0)) {
            try this._breakLpAndTopUp(routerV1, WPLS_V1, lp, amount) returns (uint256 plsTotal) {
                emit LpFeeProcessed(address(lp), amount, plsTotal, true);
                return;
            } catch {}
        }

        lp.safeTransfer(feeAddress, amount);
        emit LpFeeProcessed(address(lp), amount, 0, false);
    }

    function _breakLpAndTopUp(address _router, address _wpls, IERC20 lp, uint256 amount)
        external
        returns (uint256 plsTotal)
    {
        if (msg.sender != address(this)) revert ZeroAddress();

        address t0 = IUniswapV2Pair(address(lp)).token0();
        address t1 = IUniswapV2Pair(address(lp)).token1();

        IERC20(address(lp)).forceApprove(_router, amount);

        uint256 plsBefore = address(this).balance;

        if (t0 == _wpls || t1 == _wpls) {
            address other = t0 == _wpls ? t1 : t0;
            IPulseXRouter(_router).removeLiquidityETHSupportingFeeOnTransferTokens(
                other, amount, 0, 0, address(this), block.timestamp
            );
            uint256 otherBal = IERC20(other).balanceOf(address(this));
            if (otherBal > 0) {
                _swapTokenToPLS(_router, _wpls, other, otherBal);
            }
        } else {
            IPulseXRouter(_router).removeLiquidity(
                t0, t1, amount, 0, 0, address(this), block.timestamp
            );
            uint256 b0 = IERC20(t0).balanceOf(address(this));
            uint256 b1 = IERC20(t1).balanceOf(address(this));
            if (b0 > 0) _swapTokenToPLS(_router, _wpls, t0, b0);
            if (b1 > 0) _swapTokenToPLS(_router, _wpls, t1, b1);
        }

        plsTotal = address(this).balance - plsBefore;
        if (plsTotal == 0) revert AmountTooLow();
        IStakingVault(tieredVault).topUp{value: plsTotal}();
    }

    function _swapTokenToPLS(address _router, address _wpls, address token, uint256 amount) internal {
        IERC20(token).forceApprove(_router, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = _wpls;
        IPulseXRouter(_router).swapExactTokensForETHSupportingFeeOnTransferTokens(
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

    /// @dev True iff this pool is wired to PulseX, the global kill switch is on, and
    ///      PULSEX_MC is non-zero. Single source of truth used by every external-touch path.
    function _externalActive(PoolInfo storage pool) internal view returns (bool) {
        return externalEnabled
            && pool.externalProtocol == ExternalProtocol.PULSEX
            && PULSEX_MC != address(0);
    }

    function _externalChefHarvest(PoolInfo storage pool) internal {
        if (_externalActive(pool)) {
            IExternalChef(PULSEX_MC).deposit(pool.externalPid, 0);
        }
    }

    function _externalDepositLp(PoolInfo storage pool, uint256 amount) internal {
        if (_externalActive(pool)) {
            pool.token.forceApprove(PULSEX_MC, amount);
            IExternalChef(PULSEX_MC).deposit(pool.externalPid, amount);
            _sweepInc();
        }
    }

    function _externalWithdrawLp(PoolInfo storage pool, uint256 amount) internal {
        if (_externalActive(pool)) {
            IExternalChef(PULSEX_MC).withdraw(pool.externalPid, amount);
            _sweepInc();
        }
    }

    function _settlePending(PoolInfo storage pool, UserInfo storage user, address _staker) internal {
        if (user.amount == 0) return;
        uint256 pending = (user.amount * pool.accTokensPerShare) / 1e18 - user.rewardDebt;
        _payReward(_staker, referral[_staker], pending);
    }

    /// @dev Scan the live PulseX MC for a pool whose lpToken matches `_lp`. Returns
    ///      (false, 0) if not found, the chef is unconfigured, or the scan call reverts.
    function _findPulseXPid(address _lp) internal view returns (bool found, uint256 pid) {
        if (PULSEX_MC == address(0)) return (false, 0);
        uint256 n;
        try IExternalChef(PULSEX_MC).poolLength() returns (uint256 _n) { n = _n; } catch { return (false, 0); }
        if (n > MAX_PULSEX_SCAN) n = MAX_PULSEX_SCAN;
        for (uint256 i = 0; i < n; i++) {
            try IExternalChef(PULSEX_MC).poolInfo(i) returns (
                address lpToken, uint256, uint256, uint256
            ) {
                if (lpToken == _lp) return (true, i);
            } catch {}
        }
        return (false, 0);
    }

    function _validatePulseXMatch(address _lp, uint256 _pid) internal view {
        if (PULSEX_MC == address(0)) revert InvalidExternalFarm();
        try IExternalChef(PULSEX_MC).poolInfo(_pid) returns (
            address lpToken, uint256, uint256, uint256
        ) {
            if (lpToken != _lp) revert ManualPidMismatch();
        } catch {
            revert InvalidExternalFarm();
        }
    }

    function findPulseXPid(address _lp) external view returns (bool, uint256) {
        return _findPulseXPid(_lp);
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

    function setTieredVault(address _vault) external onlyOwner {
        tieredVault = _vault;
        emit SetTieredVault(_vault);
    }

    function setRouter(address _router) external onlyOwner {
        _initRouter(_router, false);
        emit SetRouter(_router);
    }

    function setRouterV1(address _router) external onlyOwner {
        _initRouter(_router, true);
        emit SetRouterV1(_router);
    }

    /// @notice Re-target the PulseX MC. Used if the live MC is migrated/retired. The owner
    ///         is responsible for first emergency-clearing existing wirings; this setter just
    ///         points the chef at a new MC for future scans + pass-throughs.
    function setPulseXMC(address _mc) external onlyOwner {
        PULSEX_MC = _mc;
        emit SetPulseXMC(_mc);
    }

    /// @notice Global kill switch for external pass-through. When false, every external-touch
    ///         path no-ops and pools behave like NONE (chef-local LP, no INC sweep).
    function setExternalEnabled(bool _enabled) external onlyOwner {
        externalEnabled = _enabled;
        emit SetExternalEnabled(_enabled);
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
