// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CabalEmissions} from "../src/CabalEmissions.sol";

interface ITSTTAdmin {
    function addTaxExclusion(address) external;
    function setMinter(address) external;
}

/// @title RedeployChef
/// @notice Deploys a new CabalEmissions (with the harvest()-INC-sweep patch) wired to the existing
///         TieredStakingVault, transfers the TSTT minter from the old chef to the new one,
///         tax-excludes the new chef on TSTT, and re-adds the production pools.
contract RedeployChef is Script {
    address constant DEV1 = 0xA04f1f7661fDa0C5872A41c77fCcDc335e248b2B;
    address constant DEV2 = 0xfB8eFf739D9A4DEd54e441F566C1a0aeB5B9e648;

    address constant DEFAULT_TSTT          = 0x19614B774bAeE8b8411944766765273f29e66504;
    address constant DEFAULT_VAULT         = 0x5dd3279593E20fF407ffc255a9Eb089f264F2Ea4;
    address constant DEFAULT_OLD_CHEF      = 0x66b368a328D06c1D358e8c9d2DD3927CBC326ca4;
    address constant DEFAULT_ROUTER        = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant DEFAULT_PULSEX_MC     = 0xB2Ca4A66d3e57a5a9A12043B6bAD28249fE302d4;
    address constant DEFAULT_INC           = 0x2fa878Ab3F87CC1C9737Fc071108F904c0B0C95d;

    uint256 constant DEFAULT_REWARDS_PER_SEC = 1e16;
    uint256 constant DEFAULT_DEV_PERCENT = 500;
    uint256 constant DEFAULT_FEE_PERCENT = 500;

    struct PoolSpec {
        address lp;
        uint256 allocPoint;
        uint16 depositFeeBP;
        uint16 withdrawFeeBP;
        CabalEmissions.ExternalProtocol externalProtocol;
        uint256 externalPid;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tstt     = _envOr("TSTT_ADDRESS",       DEFAULT_TSTT);
        address vault    = _envOr("TIERED_VAULT",       DEFAULT_VAULT);
        address router   = _envOr("PULSEX_ROUTER",      DEFAULT_ROUTER);
        address pxMC     = _envOr("PULSEX_MC",          DEFAULT_PULSEX_MC);
        address inc      = _envOr("INC_TOKEN",          DEFAULT_INC);
        uint256 rps      = _envOrUint("REWARDS_PER_SEC", DEFAULT_REWARDS_PER_SEC);
        uint256 startT   = _envOrUint("START_TIME", block.timestamp + 60);
        address deployer = vm.addr(pk);

        console.log("Deployer  :", deployer);
        console.log("TSTT      :", tstt);
        console.log("Vault     :", vault);
        console.log("Router    :", router);
        console.log("PXMC      :", pxMC);
        console.log("INC       :", inc);
        console.log("rps       :", rps);
        console.log("startTime :", startT);

        PoolSpec[] memory pools = _poolSpecs();

        vm.startBroadcast(pk);

        CabalEmissions chef = new CabalEmissions(CabalEmissions.InitParams({
            rewardToken:      tstt,
            devAddress:       DEV1,
            feeAddress:       DEV2,
            devPercent:       DEFAULT_DEV_PERCENT,
            feePercent:       DEFAULT_FEE_PERCENT,
            rewardsPerSec:    rps,
            startTime:        startT,
            pulseXMC:         pxMC,
            incToken:         inc,
            rehypDestination: DEV1,
            router:           router,
            tieredVault:      vault,
            defaultReferrer:  DEV1,
            owner:            deployer
        }));

        // Owner-gated on TSTT — deployer must be TSTT owner.
        ITSTTAdmin(tstt).setMinter(address(chef));
        console.log("TSTT setMinter -> new chef");
        (bool ok, ) = tstt.call(abi.encodeWithSelector(ITSTTAdmin.addTaxExclusion.selector, address(chef)));
        if (ok) console.log("addTaxExclusion OK for new chef");
        else    console.log("WARNING: addTaxExclusion FAILED - call manually");

        for (uint256 i = 0; i < pools.length; i++) {
            PoolSpec memory p = pools[i];
            chef.add(
                IERC20(p.lp),
                p.allocPoint,
                p.depositFeeBP,
                p.withdrawFeeBP,
                p.externalProtocol,
                p.externalPid,
                false
            );
            console.log("added pid", i, p.lp);
        }

        vm.stopBroadcast();

        console.log("---");
        console.log("New CabalEmissions:", address(chef));
        console.log("Otterscan: https://otter.pulsechain.com/address/", address(chef));
    }

    function _poolSpecs() internal pure returns (PoolSpec[] memory pools) {
        pools = new PoolSpec[](5);
        pools[0] = PoolSpec(0x4cE2647fAC810F46B9f5B09DA82bC5F52e152aA5, 400, 200, 200, CabalEmissions.ExternalProtocol.NONE,   0);
        pools[1] = PoolSpec(0xE56043671df55dE5CDf8459710433C10324DE0aE, 300, 100, 100, CabalEmissions.ExternalProtocol.PULSEX, 1);
        pools[2] = PoolSpec(0x42AbdFDB63f3282033C766E72Cc4810738571609, 200, 100, 100, CabalEmissions.ExternalProtocol.PULSEX, 4);
        pools[3] = PoolSpec(0x1b45b9148791d3a104184Cd5DFE5CE57193a3ee9, 200, 100, 100, CabalEmissions.ExternalProtocol.PULSEX, 0);
        pools[4] = PoolSpec(0x322Df7921F28F1146Cdf62aFdaC0D6bC0Ab80711, 200, 100, 100, CabalEmissions.ExternalProtocol.PULSEX, 5);
    }

    function _envOr(string memory k, address fb) internal view returns (address) {
        try vm.envAddress(k) returns (address v) { return v; } catch { return fb; }
    }
    function _envOrUint(string memory k, uint256 fb) internal view returns (uint256) {
        try vm.envUint(k) returns (uint256 v) { return v; } catch { return fb; }
    }
}
