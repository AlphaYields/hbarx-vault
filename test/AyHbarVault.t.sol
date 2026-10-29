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
    function setBalance(address who, uint256 v) external {
        uint256 b = balanceOf(who);
        if (v > b) _mint(who, v - b); else if (b > v) _burn(who, b - v);
    }
}

/// Lending mock with the one rule that matters here: collateral is released
/// only while the position stays healthy afterwards, exactly as the real
/// market behaves. Base currency is WHBAR units.
contract MockPool {
    MockToken a; MockToken at; MockToken dt; MockToken w;
    uint256 public rate = 1.43e8;         // WHBAR per whole asset unit, 1e8-scaled
    uint256 public constant LT  = 6828;   // liquidation threshold, bps
    uint256 public constant LTV = 6298;
    bool public enforceHealth = true;

    constructor(MockToken _a, MockToken _at, MockToken _dt, MockToken _w){a=_a;at=_at;dt=_dt;w=_w;}
    function setRate(uint256 r) external { rate = r; }
    function setEnforceHealth(bool e) external { enforceHealth = e; }

    function deposit(address, uint256 amt, address on, uint16) external { a.transferFrom(msg.sender,address(this),amt); at.mint(on,amt); }
    function withdraw(address, uint256 amt, address to) external returns (uint256){
        at.burnFrom_(msg.sender,amt);
        if (enforceHealth) require(_hf(msg.sender) >= 1e18, "HF<1");
        a.transfer(to,amt); return amt;
    }
    function borrow(address, uint256 amt, uint256, uint16, address on) external {
        dt.mint(on,amt); w.mint(msg.sender,amt);
        if (enforceHealth) require(_hf(on) >= 1e18, "HF<1");
    }
    function repay(address, uint256 amt, uint256, address on) external returns (uint256){ w.transferFrom(msg.sender,address(this),amt); dt.burnFrom_(on,amt); return amt; }
    function setUserUseReserveAsCollateral(address, bool) external {}

    function _collBase(address u) internal view returns (uint256) { return at.balanceOf(u) * rate / 1e8; }
    function _hf(address u) internal view returns (uint256) {
        uint256 d = dt.balanceOf(u);
        if (d == 0) return type(uint256).max;
        return _collBase(u) * LT / 1e4 * 1e18 / d;
    }
    function getUserAccountData(address u) external view returns (uint256,uint256,uint256,uint256,uint256,uint256){
        return (_collBase(u), dt.balanceOf(u), 0, LT, LTV, _hf(u));
    }
}

/// Staking mock: mints the asset at a protocol rate, and can be switched off
/// to reproduce an unavailable staking entry.
contract MockStaking {
    MockToken a; uint256 public rateValue = 1.43e8; bool public broken;
    constructor(MockToken _a){a=_a;}
    function setRate(uint256 r) external { rateValue = r; }
    function setBroken(bool b) external { broken = b; }
    function getExchangeRate() external view returns (uint256){ return rateValue; }
    function stake() external payable {
        require(!broken, "stake down");
        a.mint(msg.sender, msg.value * 1e8 / rateValue);
    }
}

/// Minimal WHBAR wrapper: native in, token out, and back again.
/// Native value on Hedera reaches a contract in tinybar - the same eight-decimal
/// unit as WHBAR and the asset - so these mocks map it one to one, as the real
/// wrapper does.
contract MockWhbar {
    MockToken w;
    constructor(MockToken _w){w=_w;}
    receive() external payable {}
    function deposit() external payable { w.mint(msg.sender, msg.value); }
    function withdraw(uint256 amt) external {
        w.burnFrom_(msg.sender, amt);
        (bool ok,) = msg.sender.call{value: amt}(""); require(ok, "send");
    }
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
    function setReserves(uint112 _r0,uint112 _r1) external {
        r0=_r0; r1=_r1;
        MockToken(token0).setBalance(address(this), _r0);
        MockToken(token1).setBalance(address(this), _r1);
    }
    function swap(uint256 a0,uint256 a1,address to,bytes calldata) external {
        if(a0>0) MockToken(token0).mint(to,a0);
        if(a1>0) MockToken(token1).mint(to,a1);
        // reserves move the way a real pool's would
        uint256 in0 = MockToken(token0).balanceOf(address(this));
        uint256 in1 = MockToken(token1).balanceOf(address(this));
        r0 = uint112(in0 > a0 ? in0 - a0 : 0);
        r1 = uint112(in1 > a1 ? in1 - a1 : 0);
        if (r0 == 0) r0 = 1; if (r1 == 0) r1 = 1;
    }
}

/// Concentrated-liquidity venue, reached through a router rather than by
/// transferring into a pair.
///
/// A real concentrated pool has no reserves to read, which is exactly why the
/// vault quotes it through the router and bounds the trade with a floor taken
/// from the redemption rate instead of from the pool. This mock keeps that
/// shape: one settable price, the fee tier applied in parts per million, and
/// the minimum-out check the router itself performs.
contract MockRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    MockToken whbar; MockToken asset_;
    uint256 public price = 1.43e8;        // WHBAR per whole asset unit, 1e8

    constructor(MockToken w, MockToken a) { whbar = w; asset_ = a; }
    function setPrice(uint256 p) external { price = p; }

    function exactInputSingle(ExactInputSingleParams calldata q)
        external payable returns (uint256 out)
    {
        require(q.deadline >= block.timestamp, "expired");
        require(q.tokenIn != q.tokenOut, "same token");
        // Pulled with an allowance, so the router approvals are exercised too.
        require(MockToken(q.tokenIn).transferFrom(msg.sender, address(this), q.amountIn), "pull failed");

        out = q.tokenIn == address(whbar)
            ? q.amountIn * 1e8 / price            // WHBAR in, asset out
            : q.amountIn * price / 1e8;           // asset in, WHBAR out
        out = out * (1e6 - q.fee) / 1e6;          // the pool's fee tier

        require(out >= q.amountOutMinimum, "too little received");
        MockToken(q.tokenOut).mint(q.recipient, out);
    }
}

/// A contract that is not a pair, used to prove a venue must prove itself.
contract NotAPair {
    function token0() external view returns (address) { return address(this); }
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
        // Priced in line with the oracle and deep enough that a test-sized trade
        // barely moves it, so the anchored slippage floor is not tripped by the
        // mock's own shallowness.
        pair  = new MockPair(address(whbar),address(hbarx),uint112(143_000*ONE),uint112(100_000*ONE));
        whbar.mint(address(pair), 143_000*ONE);
        hbarx.mint(address(pair), 100_000*ONE);
        oracle.set(address(whbar),1e18); oracle.set(address(hbarx),1.43e18);

        v = new AyHbarVault(IERC20(address(hbarx)), address(pool), address(pair), address(whbar),
            address(0), address(aTok), address(dTok), address(oracle), address(0), feeRcv);
        v.setRoles(guardian, curator);

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
        v.configureStrategy(address(oracle), address(0), 300, 100, 1.4e18, 1.15e18);
        assertEq(v.maxSlippageBps(), 300);                  // owner raises it
        vm.expectRevert();                                  // but not past the 5% ceiling
        v.configureStrategy(address(oracle), address(0), 501, 100, 1.4e18, 1.15e18);
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

    // ══════════════════════════════════════════════════ pricing and routing

    /// Set up a vault wired to staking and a second pool, as mainnet is.
    function _withStakingAndTwoVenues() internal returns (MockStaking st, MockPair pair2) {
        st = new MockStaking(hbarx);
        MockWhbar wrap = new MockWhbar(whbar);
        vm.deal(address(wrap), 1_000_000 * ONE);
        AyHbarVault nv = new AyHbarVault(
            IERC20(address(hbarx)), address(pool), address(pair), address(whbar),
            address(wrap), address(aTok), address(dTok), address(oracle), address(st), feeRcv);
        vm.startPrank(address(nv));
        hbarx.approve(address(pool), type(uint256).max);
        whbar.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        nv.setRoles(guardian, curator);
        pair2 = new MockPair(address(whbar), address(hbarx), uint112(143_000*ONE), uint112(100_000*ONE));
        whbar.mint(address(pair2), 143_000*ONE);
        hbarx.mint(address(pair2), 100_000*ONE);
        nv.addVenue(address(pair2), 997, 0);
        v = nv;
    }

    /// The share price follows the staking protocol's redemption rate, not what
    /// a pool happens to quote. Pushing the pool does not move NAV.
    function test_navFollowsProtocolRateNotPoolPrice() public {
        (MockStaking st,) = _withStakingAndTwoVenues();
        _dep(alice, 100*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 10*ONE);

        uint256 navBefore = v.totalAssets();
        pair.setReserves(uint112(1*ONE), uint112(500_000*ONE));   // pool price collapses
        assertEq(v.totalAssets(), navBefore, "pool price moved the share price");

        st.setRate(1.5e8);                                        // the protocol rate moves
        oracle.set(address(hbarx), 1.5e18);
        assertGt(v.totalAssets(), navBefore, "protocol rate did not move the share price");
    }

    /// When the two price sources disagree beyond the tolerance, the vault
    /// refuses to price rather than picking one.
    function test_navRefusesWhenSourcesDisagree() public {
        (MockStaking st,) = _withStakingAndTwoVenues();
        _dep(alice, 100*ONE);
        dTok.mint(address(v), 10*ONE);
        v.totalAssets();                       // agrees today

        st.setRate(2.0e8);                     // 40% apart from the oracle's 1.43
        vm.expectRevert(AyHbarVault.OracleDisagreement.selector);
        v.totalAssets();
    }

    /// A swap is floored against the redemption rate, so a pushed pool is
    /// rejected instead of being traded into.
    function test_swapFloorRejectsPushedPool() public {
        (MockStaking st, MockPair pair2) = _withStakingAndTwoVenues();
        _dep(alice, 1000*ONE);
        vm.prank(curator); v.supplyToPool(0);

        // With staking open the vault would simply route around a bad pool, so
        // close that route and leave it no alternative.
        st.setBroken(true);
        pair.setReserves(uint112(300_000*ONE), uint112(100_000*ONE));
        pair2.setReserves(uint112(300_000*ONE), uint112(100_000*ONE));

        vm.prank(curator);
        vm.expectRevert();
        v.leverUp(1, 100*ONE, 100);
    }

    /// Unwinding sells only what the repayment needs and leaves nothing behind.
    function test_unwindStrandsNoBorrowedToken() public {
        _withStakingAndTwoVenues();
        _dep(alice, 1000*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 100*ONE);
        whbar.mint(address(pool), 1_000*ONE);          // the pool can be repaid

        uint256 navBefore = v.totalAssets();
        vm.prank(guardian); v.deleverage(1, 300*ONE, 100);

        assertEq(dTok.balanceOf(address(v)), 0, "debt not cleared");
        // What remains is the slippage allowance on the final purchase, not the
        // whole idle balance the old sizing would have sold.
        assertLe(whbar.balanceOf(address(v)), 2*ONE, "borrowed token stranded");
        assertGt(v.totalAssets(), navBefore * 97 / 100, "value lost unwinding");
    }

    /// Whatever borrowed token does end up in the vault is counted as an asset
    /// and can be converted back.
    function test_looseBorrowedTokenIsCountedAndRecoverable() public {
        _withStakingAndTwoVenues();
        _dep(alice, 100*ONE);
        uint256 navBefore = v.totalAssets();

        whbar.mint(address(v), 10*ONE);
        assertGt(v.totalAssets(), navBefore, "loose balance not in NAV");

        uint256 got = v.recoverWhbar();
        assertGt(got, 0);
        assertEq(whbar.balanceOf(address(v)), 0);
    }

    /// Under leverage the vault advertises only what it can actually pay, and a
    /// withdrawal unwinds enough leverage to settle without anyone intervening.
    function test_withdrawalUnderLeverageIsHonestAndSelfServing() public {
        _withStakingAndTwoVenues();
        v.setWithdrawTimelock(0);
        _dep(alice, 1000*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 400*ONE);
        whbar.mint(address(pool), 10_000*ONE);

        uint256 shares = v.balanceOf(alice);
        assertLt(v.maxRedeem(alice), shares, "advertised more than it can pay");

        uint256 before = hbarx.balanceOf(alice);
        uint256 claimable = v.maxRedeem(alice);
        vm.prank(alice);
        v.redeem(claimable, alice, alice);
        assertGt(hbarx.balanceOf(alice), before, "nothing paid out");
    }

    /// The HBAR deposit counts its own amount against the cap once, not twice.
    function test_hbarDepositCountsCapOnce() public {
        _withStakingAndTwoVenues();
        _dep(alice, 400*ONE);
        v.setDepositCap(1000*ONE);

        vm.deal(alice, 1000 * ONE);
        vm.prank(alice);
        v.depositHBAR{value: 350 * ONE}(alice, 0);      // 350 HBAR, headroom 600
        assertGt(v.balanceOf(alice), 0);
    }

    /// Deposits take the better of staking and the pools, and keep working when
    /// the staking entry is unavailable.
    function test_depositRoutesToTheBetterVenueAndSurvivesStakingOutage() public {
        (MockStaking st,) = _withStakingAndTwoVenues();
        vm.deal(alice, 1000 * ONE);

        // 10 HBAR at a rate of 1.43 is about 6.99 of the asset. A scaling slip
        // anywhere in this path shows up here as a wildly wrong amount, which is
        // what makes this assertion worth having.
        vm.prank(alice);
        v.depositHBAR{value: 10 * ONE}(alice, 0);
        assertApproxEqRel(v.totalAssets(), 10 * ONE * 1e8 / 1.43e8, 0.02e18,
                          "wrong amount for 10 HBAR");

        st.setBroken(true);                             // staking entry goes down
        vm.prank(alice);
        v.depositHBAR{value: 10 * ONE}(alice, 0);
        assertApproxEqRel(v.totalAssets(), 2 * (10 * ONE * 1e8 / 1.43e8), 0.02e18,
                          "wrong amount via the pool");
    }

    /// A cross-venue trade must leave the vault with more than it started with.
    function test_arbitrageOnlySettlesWhenItAdds() public {
        (, MockPair pair2) = _withStakingAndTwoVenues();
        _dep(alice, 1000*ONE);

        // Both venues priced the same: a round trip pays two fees and loses.
        vm.prank(curator);
        vm.expectRevert(AyHbarVault.NoProfit.selector);
        v.arbitrage(0, 1, 10*ONE, 0);

        // Second venue now pays well above the first for the asset: sell there,
        // buy back on the first, and the round trip adds.
        pair2.setReserves(uint112(200_000*ONE), uint112(100_000*ONE));
        uint256 before = v.totalAssets();
        vm.prank(curator);
        uint256 profit = v.arbitrage(1, 0, 10*ONE, 0);
        assertGt(profit, 0);
        assertGt(v.totalAssets(), before, "arbitrage did not add to the vault");
    }

    // ══════════════════════════════════════ concentrated-liquidity venues

    /// The mainnet shape: a constant-product pair as venue 0, a second pair as
    /// venue 1, and a concentrated pool reached through a router as venue 2.
    function _withRouterVenue() internal returns (MockStaking st, MockPair pair2, MockRouter router) {
        (st, pair2) = _withStakingAndTwoVenues();
        router = new MockRouter(whbar, hbarx);
        v.setSwapRouter(address(router));
        v.addVenue(address(0xC0CE), 1500, 1);        // fee tier 0.15%, concentrated
    }

    /// Setting the router approves it for both legs, which is what lets the
    /// vault trade through it at all.
    function test_routerIsApprovedForBothLegs() public {
        (, , MockRouter router) = _withRouterVenue();
        assertGt(hbarx.allowance(address(v), address(router)), 0, "asset leg not approved");
        assertGt(whbar.allowance(address(v), address(router)), 0, "WHBAR leg not approved");
    }

    /// Registering a concentrated venue cannot disturb deposits. It has no
    /// reserves to quote, so automatic routing never picks it, and a deposit
    /// goes where it went before.
    function test_concentratedVenueLeavesDepositRoutingAlone() public {
        _withRouterVenue();
        uint256 shares = _dep(alice, 100*ONE);
        assertGt(shares, 0);
        assertEq(v.totalAssets(), 100*ONE);

        vm.deal(bob, 10*ONE);
        vm.prank(bob);
        v.depositHBAR{value: 10*ONE}(bob, 0);
        assertGt(v.balanceOf(bob), 0, "HBAR deposit stopped working");
    }

    /// Sell the asset on the constant-product pair, buy it back on the
    /// concentrated pool.
    function test_arbitrageIntoTheConcentratedVenue() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);

        // The concentrated pool sells the asset cheaply: 1.30 WHBAR buys one,
        // where the pair wants 1.43.
        router.setPrice(1.30e8);
        uint256 before = v.totalAssets();
        vm.prank(curator);
        uint256 profit = v.arbitrage(0, 2, 10*ONE, 0);
        assertGt(profit, 0);
        assertGt(v.totalAssets(), before, "arbitrage did not add to the vault");
    }

    /// Sell the asset on the concentrated pool, buy it back on the pair.
    function test_arbitrageOutOfTheConcentratedVenue() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);

        // The concentrated pool pays 1.60 WHBAR for an asset the pair sells
        // for 1.43.
        router.setPrice(1.60e8);
        uint256 before = v.totalAssets();
        vm.prank(curator);
        uint256 profit = v.arbitrage(2, 0, 10*ONE, 0);
        assertGt(profit, 0);
        assertGt(v.totalAssets(), before, "arbitrage did not add to the vault");
    }

    /// Sell the asset on the concentrated pool and mint it back at the
    /// redemption rate. No pool is involved on the way back.
    function test_arbitrageFromTheConcentratedVenueIntoStaking() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);

        router.setPrice(1.60e8);                 // above the 1.43 redemption rate
        uint256 before = v.totalAssets();
        vm.prank(curator);
        uint256 profit = v.arbitrage(2, type(uint256).max, 10*ONE, 0);
        assertGt(profit, 0);
        assertGt(v.totalAssets(), before, "staking round trip did not add");
    }

    /// Sell on the pair and mint back through staking when the pair pays over
    /// the redemption rate: the same route, the other way round.
    function test_arbitrageFromThePairIntoStaking() public {
        (, MockPair pair2, ) = _withRouterVenue();
        _dep(alice, 1000*ONE);

        // The second pair now pays well above redemption for the asset.
        pair2.setReserves(uint112(200_000*ONE), uint112(100_000*ONE));
        uint256 before = v.totalAssets();
        vm.prank(curator);
        uint256 profit = v.arbitrage(1, type(uint256).max, 10*ONE, 0);
        assertGt(profit, 0);
        assertGt(v.totalAssets(), before, "staking round trip did not add");
    }

    /// Priced in line, every direction loses to the fees and the vault refuses
    /// all of them. Profitability is decided by the contract, not the caller.
    function test_noDirectionSettlesWhenNoneProfits() public {
        _withRouterVenue();
        _dep(alice, 1000*ONE);

        uint256 stake = type(uint256).max;
        uint256[7] memory sells = [uint256(0), 0, 1, 1, 2, 2, 0];
        uint256[7] memory buys  = [uint256(1), 2, 0, 2, 0, 1, stake];
        for (uint256 k = 0; k < 7; k++) {
            vm.prank(curator);
            vm.expectRevert();
            v.arbitrage(sells[k], buys[k], 10*ONE, 0);
        }
        assertEq(v.totalAssets(), 1000*ONE, "a losing round trip settled");
    }

    /// A profitable route still has to clear the caller's own floor.
    function test_arbitrageRespectsTheCallersProfitFloor() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);
        router.setPrice(1.60e8);

        vm.prank(curator);
        vm.expectRevert(AyHbarVault.NoProfit.selector);
        v.arbitrage(2, 0, 10*ONE, 100*ONE);      // asks for more than it makes
    }

    /// Only the curator or the owner may arbitrage.
    function test_arbitrageIsNotPublic() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);
        router.setPrice(1.60e8);

        vm.prank(bob);
        vm.expectRevert(AyHbarVault.NotAuthorized.selector);
        v.arbitrage(2, 0, 10*ONE, 0);
    }

    /// A venue has to prove what it is before it is trusted with a trade.
    function test_venueRegistrationIsChecked() public {
        _withStakingAndTwoVenues();
        address notAPair = address(new NotAPair());

        vm.expectRevert();                                  // not a pair at all
        v.addVenue(notAPair, 997, 0);

        vm.expectRevert(AyHbarVault.InvalidParam.selector);  // already registered
        v.addVenue(address(pair), 997, 0);

        vm.expectRevert(AyHbarVault.InvalidParam.selector);  // unknown kind
        v.addVenue(address(0xBEEF), 997, 2);

        vm.expectRevert(AyHbarVault.InvalidParam.selector);  // concentrated, no router
        v.addVenue(address(0xBEEF), 1500, 1);

        vm.prank(bob);                                       // and only the owner
        vm.expectRevert();
        v.addVenue(address(0xBEEF), 1500, 1);
    }

    /// A concentrated venue can be switched off like any other.
    function test_concentratedVenueCanBeRetired() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);
        router.setPrice(1.60e8);

        v.setVenueActive(2, false);
        vm.prank(curator);
        vm.expectRevert(AyHbarVault.InvalidParam.selector);
        v.arbitrage(2, 0, 10*ONE, 0);
    }

    /// The router cannot be used to take value out: the floor it is handed
    /// comes from the redemption rate, so a router returning less than the
    /// trade is worth reverts the whole call.
    function test_concentratedSwapIsFloored() public {
        (, , MockRouter router) = _withRouterVenue();
        _dep(alice, 1000*ONE);

        router.setPrice(0.70e8);                 // pays half what the asset is worth
        vm.prank(curator);
        vm.expectRevert();
        v.arbitrage(2, 0, 10*ONE, 0);
        assertEq(v.totalAssets(), 1000*ONE);
    }

    /// Leverage must leave the position at or above the configured health floor.
    function test_leverageRespectsTheHealthFloor() public {
        _withStakingAndTwoVenues();
        _dep(alice, 1000*ONE);
        vm.prank(curator); v.supplyToPool(0);

        vm.prank(curator);
        vm.expectRevert();
        v.leverUp(5, 500*ONE, 100);                     // would land under the floor
    }

    /// Anyone may unwind once the position is unhealthy, and nobody may churn a
    /// healthy one.
    function test_unwindIsPermissionlessOnlyWhenUnhealthy() public {
        _withStakingAndTwoVenues();
        _dep(alice, 1000*ONE);
        vm.prank(curator); v.supplyToPool(0);
        dTok.mint(address(v), 100*ONE);
        whbar.mint(address(pool), 10_000*ONE);

        vm.prank(bob);
        vm.expectRevert(AyHbarVault.NotAuthorized.selector);
        v.deleverage(1, 50*ONE, 100);                   // healthy: refused

        dTok.mint(address(v), 780*ONE);                 // health factor now ~1.1
        vm.prank(bob);
        v.deleverage(1, 50*ONE, 100);                   // permitted
    }
}
