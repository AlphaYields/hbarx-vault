// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AyHbarVault} from "../src/AyHbarVault.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    uint8 private d;
    constructor(string memory n, uint8 dec) ERC20(n, n) { d = dec; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 v) external { _mint(to, v); }
    function burnFrom_(address f, uint256 v) external { _burn(f, v); }
}

contract MockPool {
    MockToken a; MockToken at; MockToken dt; MockToken w;
    constructor(MockToken _a, MockToken _at, MockToken _dt, MockToken _w){a=_a;at=_at;dt=_dt;w=_w;}
    function deposit(address, uint256 amt, address on, uint16) external { a.transferFrom(msg.sender,address(this),amt); at.mint(on,amt); }
    function withdraw(address, uint256 amt, address to) external returns (uint256){ at.burnFrom_(msg.sender,amt); a.transfer(to,amt); return amt; }
    function borrow(address, uint256 amt, uint256, uint16, address on) external { dt.mint(on,amt); w.mint(msg.sender,amt); }
    function repay(address, uint256 amt, uint256, address on) external returns (uint256){ w.transferFrom(msg.sender,address(this),amt); dt.burnFrom_(on,amt); return amt; }
    function setUserUseReserveAsCollateral(address, bool) external {}
    function getUserAccountData(address) external pure returns (uint256,uint256,uint256,uint256,uint256,uint256){ return (0,0,0,0,0,type(uint256).max); }
}

contract MockOracle {
    mapping(address=>uint256) public p; bool public broken;
    function set(address a,uint256 v) external { p[a]=v; }
    function setBroken(bool b) external { broken=b; }
    function getAssetPrice(address a) external view returns (uint256){ require(!broken,"down"); return p[a]; }
}

contract MockPair {
    address public token0; address public token1; uint112 r0; uint112 r1;
    constructor(address t0,address t1,uint112 _r0,uint112 _r1){token0=t0;token1=t1;r0=_r0;r1=_r1;}
    function getReserves() external view returns (uint112,uint112,uint32){ return (r0,r1,0); }
    function setReserves(uint112 _r0,uint112 _r1) external { r0=_r0; r1=_r1; }
    function swap(uint256 a0,uint256 a1,address to,bytes calldata) external {
        if(a0>0) MockToken(token0).mint(to,a0);
        if(a1>0) MockToken(token1).mint(to,a1);
    }
}

contract AyHbarVaultTest is Test {
    MockToken hbarx; MockToken whbar; MockToken aTok; MockToken dTok;
    MockPool pool; MockOracle oracle; MockPair pair;
    AyHbarVault v;

    address owner    = address(this);
    address guardian = address(0x6A1D);
    address curator  = address(0xC0A7);
    address feeRcv   = address(0xFEE5);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);

    uint256 constant ONE = 1e8;          // 1 HBARX

    function setUp() public {
        hbarx = new MockToken("HBARX",8); whbar = new MockToken("WHBAR",8);
        aTok  = new MockToken("aHBARX",8); dTok = new MockToken("dWHBAR",8);
        pool  = new MockPool(hbarx,aTok,dTok,whbar);
        oracle= new MockOracle();
        pair  = new MockPair(address(whbar),address(hbarx),uint112(1000*ONE),uint112(700*ONE));
        oracle.set(address(whbar),1e18); oracle.set(address(hbarx),1.43e18);

        v = new AyHbarVault(IERC20(address(hbarx)), address(pool), address(pair), address(whbar),
            address(0), address(aTok), address(dTok), address(oracle), address(0), feeRcv);
        v.setGuardian(guardian); v.setCurator(curator);

        // associate() needs the HTS precompile; reproduce only its approval effect
        vm.startPrank(address(v));
        hbarx.approve(address(pool), type(uint256).max);
        whbar.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        hbarx.mint(alice, 10_000*ONE); hbarx.mint(bob, 10_000*ONE);
    }

    function _dep(address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        hbarx.approve(address(v), type(uint256).max);
        uint256 s = v.deposit(amt, who);
        vm.stopPrank();
        return s;
    }
    /// Simulate yield by sending assets to the vault.
    function _earn(uint256 amt) internal { hbarx.mint(address(v), amt); }

    // ───────────────────────────────────────────────────────────── metadata
    function test_metadata() public view {
        assertEq(v.symbol(), "ayHBAR");
        assertEq(v.name(), "AlphaYields HBAR Vault");
        assertEq(v.asset(), address(hbarx));
        assertEq(v.decimals(), 14);                  // 8 asset + 6 offset
        assertEq(v.performanceFee(), 2000);          // 20%
        assertEq(v.managementFee(), 0);              // 0%
    }

    function test_pricePerShareStartsAtOne() public {
        _dep(alice, 100*ONE);
        assertApproxEqRel(v.pricePerShare(), ONE, 1e12, "share price should start at 1.0");
    }

    // ───────────────────────────────────────────────────────────────── fees
    function test_performanceFeeIsTwentyPercentOfGain() public {
        _dep(alice, 1000*ONE);
        _earn(100*ONE);                               // +10% gain
        v.accrueFees();
        uint256 feeAssets = v.convertToAssets(v.balanceOf(feeRcv));
        assertApproxEqRel(feeAssets, 20*ONE, 1e16, "fee should be 20% of the 100 gain");
    }

    function test_noFeeWithoutGain() public {
        _dep(alice, 1000*ONE);
        v.accrueFees();
        assertEq(v.balanceOf(feeRcv), 0, "no gain, no fee");
    }

    function test_highWaterMarkPreventsDoubleCharging() public {
        _dep(alice, 1000*ONE);
        _earn(100*ONE); v.accrueFees();
        uint256 feeAfterFirst = v.balanceOf(feeRcv);

        // give back the gain, then earn it again — no new fee until above HWM
        vm.prank(address(v)); hbarx.transfer(address(0xdead), 100*ONE);
        v.accrueFees();
        assertEq(v.balanceOf(feeRcv), feeAfterFirst, "fee charged during drawdown");

        _earn(100*ONE); v.accrueFees();
        assertApproxEqRel(v.balanceOf(feeRcv), feeAfterFirst, 2e16, "double-charged on recovery");
    }

    function test_managementFeeAccruesOverTime() public {
        v.setFees(0, 200, feeRcv);                    // 0% perf, 2% mgmt
        _dep(alice, 1000*ONE);
        vm.warp(block.timestamp + 365 days);
        v.accrueFees();
        uint256 feeAssets = v.convertToAssets(v.balanceOf(feeRcv));
        assertApproxEqRel(feeAssets, 20*ONE, 5e16, "2% of 1000 over a year");
    }

    function test_feeBoundsEnforced() public {
        vm.expectRevert(); v.setFees(5001, 0, feeRcv);        // perf > 50%
        vm.expectRevert(); v.setFees(2000, 501, feeRcv);      // mgmt > 5%
        vm.expectRevert(); v.setFees(2000, 0, address(0));    // zero recipient
    }

    function test_feesAreAdjustable() public {
        v.setFees(1000, 100, bob);
        assertEq(v.performanceFee(), 1000);
        assertEq(v.managementFee(), 100);
        assertEq(v.feeRecipient(), bob);
    }

    // ──────────────────────────────────────────────────────────────── roles
    function test_rolePermissions() public {
        vm.startPrank(bob);
        vm.expectRevert(); v.supplyToPool(0);          // not curator
        vm.expectRevert(); v.pause();                  // not guardian
        vm.expectRevert(); v.setFees(100,0,bob);       // not owner
        vm.expectRevert(); v.setWithdrawTimelock(1);   // not owner
        vm.stopPrank();

        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);          // curator may run strategy
        vm.prank(guardian); v.pause();                 // guardian may pause
        vm.prank(guardian); vm.expectRevert(); v.unpause();   // but not unpause
        v.unpause();                                   // owner may
    }

    function test_ownerInheritsDelegateRoles() public {
        _dep(alice, 100*ONE);
        v.supplyToPool(0);    // owner acting as curator
        v.pause();            // owner acting as guardian
        v.unpause();
    }

    // ────────────────────────────────────────────────────────── deposit cap
    function test_depositCapEnforcedAndAdjustable() public {
        vm.prank(curator); v.setDepositCap(500*ONE);
        _dep(alice, 400*ONE);
        assertEq(v.maxDeposit(alice), 100*ONE);

        vm.startPrank(bob);
        hbarx.approve(address(v), type(uint256).max);
        vm.expectRevert(); v.deposit(200*ONE, bob);    // over cap
        v.deposit(100*ONE, bob);                       // exactly to cap
        vm.stopPrank();
        assertEq(v.maxDeposit(bob), 0);

        vm.prank(curator); v.setDepositCap(1000*ONE);  // raise it
        assertEq(v.maxDeposit(bob), 500*ONE);
    }

    // ─────────────────────────────────────────────────────── withdrawal queue
    function test_timelockBlocksImmediateExit() public {
        v.setWithdrawTimelock(1 days);
        uint256 s = _dep(alice, 100*ONE);

        vm.startPrank(alice);
        vm.expectRevert();  v.redeem(s, alice, alice);          // no request yet
        v.requestWithdraw(s);
        assertEq(v.balanceOf(alice), 0, "shares should be escrowed");
        vm.expectRevert();  v.redeem(s, alice, alice);          // not matured
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice); v.redeem(s, alice, alice);
        assertApproxEqRel(hbarx.balanceOf(alice), 10_000*ONE, 1e14, "should be whole again");
        assertEq(v.totalQueuedShares(), 0);
    }

    function test_requestCanBeCancelled() public {
        v.setWithdrawTimelock(1 days);
        uint256 s = _dep(alice, 100*ONE);
        vm.startPrank(alice);
        v.requestWithdraw(s);
        v.cancelWithdrawRequest();
        assertEq(v.balanceOf(alice), s, "shares returned");
        vm.stopPrank();
        assertEq(v.totalQueuedShares(), 0);
    }

    function test_queuedSharesStillEarn() public {
        v.setWithdrawTimelock(1 days);
        uint256 s = _dep(alice, 1000*ONE);
        vm.prank(alice); v.requestWithdraw(s);
        _earn(100*ONE);                                  // yield while queued
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice); uint256 out = v.redeem(s, alice, alice);
        assertGt(out, 1000*ONE, "queued shares should have earned");
    }

    /// A third party must not be able to take someone's matured request.
    function test_cannotStealAnothersMaturedRequest() public {
        v.setWithdrawTimelock(1 days);
        uint256 s = _dep(alice, 100*ONE);
        vm.prank(alice); v.requestWithdraw(s);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert();                                // no allowance
        v.redeem(s, bob, alice);
    }

    function test_approvedSpenderCanRedeemRequest() public {
        v.setWithdrawTimelock(1 days);
        uint256 s = _dep(alice, 100*ONE);
        vm.startPrank(alice); v.requestWithdraw(s); v.approve(bob, s); vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob); v.redeem(s, bob, alice);
        assertGt(hbarx.balanceOf(bob), 10_000*ONE, "spender received the assets");
    }

    function test_zeroTimelockGivesInstantExit() public {
        uint256 s = _dep(alice, 100*ONE);
        vm.prank(alice); v.redeem(s, alice, alice);       // no request needed
        assertEq(v.balanceOf(alice), 0);
    }

    function test_timelockBoundEnforced() public {
        vm.expectRevert(); v.setWithdrawTimelock(31 days);
        v.setWithdrawTimelock(30 days);                   // at the bound
    }

    // ────────────────────────────────────────────────────────────── pausing
    function test_pauseStopsDepositsAndWithdrawals() public {
        uint256 s = _dep(alice, 100*ONE);
        vm.prank(guardian); v.pause();
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.maxRedeem(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(); v.deposit(1*ONE, alice);
        vm.expectRevert(); v.redeem(s, alice, alice);
        vm.expectRevert(); v.withdraw(1*ONE, alice, alice);
        vm.stopPrank();

        v.unpause();                                       // owner lifts it
        vm.prank(alice); v.redeem(s, alice, alice);        // exits resume
        assertEq(v.balanceOf(alice), 0);
    }

    /// Unwinding leverage must stay available while paused.
    function test_deleverageWorksWhilePaused() public {
        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 10*ONE);
        vm.prank(guardian); v.pause();
        vm.prank(guardian); v.deleverage(1, 20*ONE, 100);  // still permitted
    }

    /// The curator cannot give away value through slippage beyond the owner's limit.
    function test_slippageIsBounded() public {
        _dep(alice, 100*ONE);
        vm.prank(curator);
        vm.expectRevert(); v.leverUp(1, 1*ONE, 101);        // above the 1% default
        v.setMaxSlippageBps(300);                           // owner raises it
        assertEq(v.maxSlippageBps(), 300);
        vm.expectRevert(); v.setMaxSlippageBps(501);        // but not past the 5% ceiling
    }

    function test_borrowedAssetIsProtectedFromSweep() public {
        vm.expectRevert(); v.sweep(address(whbar), owner, 1);
    }

    // ─────────────────────────────────────────────────────────────── safety
    function test_inflationAttackMitigated() public {
        vm.startPrank(alice);
        hbarx.approve(address(v), type(uint256).max);
        v.deposit(1, alice);
        hbarx.transfer(address(v), 500*ONE);
        vm.stopPrank();
        uint256 s = _dep(bob, 100*ONE);
        assertGt(s, 0, "victim got no shares");
        assertGt(v.previewRedeem(s), 99*ONE, "victim lost too much");
    }

    function test_noRoleCanTakeUserFunds() public {
        _dep(alice, 100*ONE);
        vm.expectRevert(); v.sweep(address(hbarx), owner, 100*ONE);
        vm.expectRevert(); v.sweep(address(aTok), owner, 1);
        vm.expectRevert(); v.sweep(address(dTok), owner, 1);
        vm.prank(curator); vm.expectRevert(); v.sweep(address(whbar), curator, 1);
    }

    function test_navIgnoresAmmPrice() public {
        _dep(alice, 100*ONE);
        dTok.mint(address(v), 10*ONE);
        uint256 before = v.totalAssets();
        pair.setReserves(uint112(ONE), uint112(100_000*ONE));
        assertEq(v.totalAssets(), before, "AMM moved the NAV");
    }

    function test_deadOracleWithDebtReverts() public {
        _dep(alice, 100*ONE);
        dTok.mint(address(v), 10*ONE);
        oracle.setBroken(true);
        vm.expectRevert();
        v.totalAssets();
    }

    function test_noDebtNeedsNoOracle() public {
        _dep(alice, 100*ONE);
        oracle.setBroken(true);
        assertEq(v.totalAssets(), 100*ONE);
        vm.prank(alice); v.withdraw(50*ONE, alice, alice);
    }

    function test_withdrawPullsFromCollateral() public {
        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);
        assertEq(hbarx.balanceOf(address(v)), 0);
        vm.prank(alice); v.withdraw(40*ONE, alice, alice);
        assertEq(hbarx.balanceOf(alice), 9_940*ONE);
    }

    function test_guardianCanEmergencyDeleverage() public {
        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 10*ONE);
        vm.prank(guardian); v.deleverage(1, 20*ONE, 100);   // allowed
        vm.prank(bob); vm.expectRevert(); v.deleverage(1, 20*ONE, 100);
    }

    // ───────────────────────────────────────────────────────────────── fuzz
    function testFuzz_depositRedeemNeverProfits(uint96 amt) public {
        amt = uint96(bound(amt, 1e4, 1e13));
        hbarx.mint(address(0xBEEF), amt);
        vm.startPrank(address(0xBEEF));
        hbarx.approve(address(v), type(uint256).max);
        uint256 s = v.deposit(amt, address(0xBEEF));
        uint256 out = v.redeem(s, address(0xBEEF), address(0xBEEF));
        vm.stopPrank();
        assertLe(out, amt, "extracted more than deposited");
    }

    function testFuzz_feeNeverExceedsGain(uint96 dep, uint96 gain) public {
        dep  = uint96(bound(dep, 1e8, 1e13));
        gain = uint96(bound(gain, 1e4, 1e12));
        hbarx.mint(alice, dep);              // fund whatever the fuzzer picked
        _dep(alice, dep);
        _earn(gain);
        v.accrueFees();
        uint256 feeAssets = v.convertToAssets(v.balanceOf(feeRcv));
        assertLe(feeAssets, uint256(gain) * 2100 / 10000, "fee exceeded 21% of the gain");
    }

    function testFuzz_capNeverExceeded(uint96 cap, uint96 amt) public {
        cap = uint96(bound(cap, 1e8, 1e13));
        amt = uint96(bound(amt, 1e4, 1e14));
        v.setDepositCap(cap);
        hbarx.mint(alice, amt);
        vm.startPrank(alice);
        hbarx.approve(address(v), type(uint256).max);
        if (amt > cap) { vm.expectRevert(); v.deposit(amt, alice); }
        else { v.deposit(amt, alice); assertLe(v.totalAssets(), cap); }
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────── caps with no cap configured
    /// With no cap configured, maxDeposit is unbounded and maxMint must still
    /// answer rather than overflow — ERC-4626 requires both never to revert.
    function test_uncappedVaultStillQuotesAndMints() public {
        _dep(alice, 100*ONE);                        // non-zero assets and supply
        assertEq(v.depositCap(), type(uint256).max);
        assertEq(v.maxDeposit(alice), type(uint256).max);
        assertEq(v.maxMint(alice), type(uint256).max);

        uint256 want = 10*ONE * 10 ** 6;             // 10 HBARX worth of shares
        vm.startPrank(bob);
        hbarx.approve(address(v), type(uint256).max);
        v.mint(want, bob);
        vm.stopPrank();
        assertEq(v.balanceOf(bob), want);
    }

    function test_withdrawFromPoolZeroMeansEverything() public {
        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);
        assertEq(v.totalAssets(), 100*ONE);
        assertEq(aTok.balanceOf(address(v)), 100*ONE);

        vm.prank(curator); v.withdrawFromPool(0);
        assertEq(aTok.balanceOf(address(v)), 0);
        assertEq(hbarx.balanceOf(address(v)), 100*ONE);
        assertEq(v.totalAssets(), 100*ONE);          // value conserved either way
    }

    function test_emptyPoolWithdrawalIsRejected() public {
        vm.prank(curator);
        vm.expectRevert();
        v.withdrawFromPool(0);
    }
}
