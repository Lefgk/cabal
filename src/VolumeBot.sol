// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPulseXRouter} from "./interfaces/IPulseXRouter.sol";

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title VolumeBot
/// @notice Self-custodied volume helper. Owner pre-funds the bot with TSTT (via plain
///         `transfer`) and PLS (via `receive()` or any direct send). Each `fire()` performs
///         exactly ONE swap leg against the configured TSTT/WPLS pair, alternating sell→buy
///         on each call. Bot is NOT tax-excluded — every swap leg triggers the token's
///         transfer tax.
///
///         Triggering:
///         - `fire()` callable by owner OR any address in the `allowed` set
///         - Sending PLS to the contract is also a trigger (treated as a fire) when the
///           sender is owner / allowed; otherwise PLS is accepted as inventory only.
///
///         Inventory model: PLS proceeds from sell legs stay in the bot to fund the next
///         buy. Token proceeds from buy legs stay in the bot to fund the next sell. Owner
///         tops up the side that drains faster (the tax leak) via direct sends.
contract VolumeBot is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotAllowed();
    error NoOutput();

    // ─────────────── Config ───────────────
    address public volumeToken;
    address public router;
    address public WPLS;

    /// @dev Token amount used per sell leg. If bot's TSTT balance is below this, the leg is
    ///      skipped (and alternation does not advance) so the next fire retries.
    uint256 public sellAmount;
    /// @dev PLS amount used per buy leg. Same skip-without-advance behavior.
    uint256 public buyAmountPLS;

    bool public volumeEnabled = true;
    bool public nextIsSell = true;

    /// @dev `owner` is implicitly allowed; mapping covers everyone else (e.g. the V5 chef).
    mapping(address => bool) public allowed;

    // ─────────────── Events ───────────────
    event SetVolumeToken(address indexed token);
    event SetRouter(address indexed router);
    event SetSellAmount(uint256 amount);
    event SetBuyAmountPLS(uint256 amount);
    event SetVolumeEnabled(bool enabled);
    event SetAllowed(address indexed caller, bool allowed);
    event SellFired(address indexed by, uint256 tokenIn, uint256 plsOut);
    event BuyFired(address indexed by, uint256 plsIn, uint256 tokenOut);
    event Skipped(address indexed by, string reason);
    event PlsReceived(address indexed from, uint256 amount, bool triggered);

    constructor(address _owner, address _router) Ownable(_owner) {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
        WPLS = IPulseXRouter(_router).WPLS();
    }

    /// @notice Sending PLS = optional trigger. PLS is always accepted into inventory.
    ///         If the sender is owner/allowed, fire() is invoked automatically.
    receive() external payable {
        bool trig;
        if (msg.sender == owner() || allowed[msg.sender]) {
            trig = true;
        }
        emit PlsReceived(msg.sender, msg.value, trig);
        if (trig) _fireInternal(msg.sender);
    }

    // ─────────────── Admin ───────────────
    function setVolumeToken(address _t) external onlyOwner {
        if (_t == address(0)) revert ZeroAddress();
        volumeToken = _t;
        emit SetVolumeToken(_t);
    }

    function setRouter(address _r) external onlyOwner {
        if (_r == address(0)) revert ZeroAddress();
        router = _r;
        WPLS = IPulseXRouter(_r).WPLS();
        emit SetRouter(_r);
    }

    function setSellAmount(uint256 _a) external onlyOwner {
        sellAmount = _a;
        emit SetSellAmount(_a);
    }

    function setBuyAmountPLS(uint256 _a) external onlyOwner {
        buyAmountPLS = _a;
        emit SetBuyAmountPLS(_a);
    }

    function setVolumeEnabled(bool _e) external onlyOwner {
        volumeEnabled = _e;
        emit SetVolumeEnabled(_e);
    }

    function setNextIsSell(bool _s) external onlyOwner {
        nextIsSell = _s;
    }

    function setAllowed(address _caller, bool _allowed) external onlyOwner {
        if (_caller == address(0)) revert ZeroAddress();
        allowed[_caller] = _allowed;
        emit SetAllowed(_caller, _allowed);
    }

    // ─────────────── Fire ───────────────
    /// @notice Manual / chef-driven trigger. Owner or any `allowed` address.
    function fire() external nonReentrant {
        if (msg.sender != owner() && !allowed[msg.sender]) revert NotAllowed();
        _fireInternal(msg.sender);
    }

    function _fireInternal(address _by) internal {
        if (!volumeEnabled) {
            emit Skipped(_by, "disabled");
            return;
        }
        if (volumeToken == address(0)) {
            emit Skipped(_by, "unconfigured");
            return;
        }

        if (nextIsSell) {
            // Skip without flipping if leg can't run — preserves strict 1-by-1 alternation
            // even if inventory temporarily runs out.
            uint256 bal = IERC20(volumeToken).balanceOf(address(this));
            if (sellAmount == 0 || bal < sellAmount) {
                emit Skipped(_by, "low token");
                return;
            }
            _doSell(_by, sellAmount);
            nextIsSell = false;
        } else {
            uint256 bal = address(this).balance;
            if (buyAmountPLS == 0 || bal < buyAmountPLS) {
                emit Skipped(_by, "low PLS");
                return;
            }
            _doBuy(_by, buyAmountPLS);
            nextIsSell = true;
        }
    }

    /// @dev Sell `_amt` token from bot inventory for PLS via FoT-aware router. Tax fires
    ///      because `to == pair`. PLS stays in bot.
    function _doSell(address _by, uint256 _amt) internal {
        IERC20 tok = IERC20(volumeToken);
        tok.forceApprove(router, _amt);
        address[] memory path = new address[](2);
        path[0] = volumeToken;
        path[1] = WPLS;

        uint256 plsBefore = address(this).balance;
        IPulseXRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            _amt, 0, path, address(this), block.timestamp
        );
        uint256 plsOut = address(this).balance - plsBefore;
        if (plsOut == 0) revert NoOutput();
        emit SellFired(_by, _amt, plsOut);
    }

    /// @dev Buy token with `_amtPls` PLS via FoT-aware router. Tax fires because
    ///      `from == pair`. Tokens stay in bot.
    function _doBuy(address _by, uint256 _amtPls) internal {
        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = volumeToken;

        IERC20 tok = IERC20(volumeToken);
        uint256 tBefore = tok.balanceOf(address(this));
        IPulseXRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: _amtPls}(
            0, path, address(this), block.timestamp
        );
        uint256 tOut = tok.balanceOf(address(this)) - tBefore;
        if (tOut == 0) revert NoOutput();
        emit BuyFired(_by, _amtPls, tOut);
    }

    // ─────────────── Recovery ───────────────
    function recoverERC20(address _token, address _to, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function recoverPLS(address payable _to, uint256 _amount) external onlyOwner {
        (bool ok, ) = _to.call{value: _amount}("");
        require(ok, "pls send failed");
    }
}
