// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HbarxLoopVault} from "../src/HbarxLoopVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    uint8 private d;
    constructor(string memory n, uint8 dec) ERC20(n, n) { d = dec; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 v) external { _mint(to, v); }
    function burnFrom_(address from, uint256 v) external { _burn(from, v); }
}

contract MockPool {
    MockToken a; MockToken at; MockToken dt; MockToken w;
    constructor(MockToken _a, MockToken _at, MockToken _dt, MockToken _w){a=_a;at=_at;dt=_dt;w=_w;}
    function deposit(address, uint256 amt, address onBehalf, uint16) external {
        a.transferFrom(msg.sender, address(this), amt); at.mint(onBehalf, amt);
    }
    function withdraw(address, uint256 amt, address to) external returns (uint256) {
        at.burnFrom_(msg.sender, amt); a.transfer(to, amt); return amt;
    }
    function borrow(address, uint256 amt, uint256, uint16, address onBehalf) external {
        dt.mint(onBehalf, amt); w.mint(msg.sender, amt);
    }
    function repay(address, uint256 amt, uint256, address onBehalf) external returns (uint256) {
        w.transferFrom(msg.sender, address(this), amt); dt.burnFrom_(onBehalf, amt); return amt;
    }
    function setUserUseReserveAsCollateral(address, bool) external {}
    function getUserAccountData(address) external pure returns (uint256,uint256,uint256,uint256,uint256,uint256){
        return (0,0,0,0,0,type(uint256).max);
    }
}

contract MockOracle {
    mapping(address=>uint256) public p;
    bool public broken;
    function set(address a, uint256 v) external { p[a]=v; }
    function setBroken(bool b) external { broken=b; }
    function getAssetPrice(address a) external view returns (uint256){ require(!broken,"oracle down"); return p[a]; }
}

contract MockPair {
    address public token0; address public token1;
    uint112 r0; uint112 r1;
    constructor(address t0,address t1,uint112 _r0,uint112 _r1){token0=t0;token1=t1;r0=_r0;r1=_r1;}
    function getReserves() external view returns (uint112,uint112,uint32){ return (r0,r1,0); }
    function setReserves(uint112 _r0,uint112 _r1) external { r0=_r0; r1=_r1; }
    function swap(uint256 a0,uint256 a1,address to,bytes calldata) external {
        if(a0>0) MockToken(token0).mint(to,a0);
        if(a1>0) MockToken(token1).mint(to,a1);
    }
}

contract VaultSecurityTest is Test {
    MockToken hbarx; MockToken whbar; MockToken aTok; MockToken dTok;
    MockPool pool; MockOracle oracle; MockPair pair;
    HbarxLoopVault vault;
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() public {
        hbarx = new MockToken("HBARX", 8);
        whbar = new MockToken("WHBAR", 8);
        aTok  = new MockToken("aHBARX", 8);
        dTok  = new MockToken("dWHBAR", 8);
        pool  = new MockPool(hbarx, aTok, dTok, whbar);
        oracle= new MockOracle();
        pair  = new MockPair(address(whbar), address(hbarx), 1000e8, 700e8);
        oracle.set(address(whbar), 1e18);
        oracle.set(address(hbarx), 1.43e18);
        vault = new HbarxLoopVault(IERC20(address(hbarx)), address(pool), address(pair),
            address(whbar), address(0), address(aTok), address(dTok), address(oracle), address(0));
        hbarx.mint(alice, 1000e8);
        hbarx.mint(bob,   1000e8);
        // associate() needs the HTS precompile, which forge cannot provide.
        // Reproduce only its approval side-effect so pool interaction is testable.
        vm.startPrank(address(vault));
        hbarx.approve(address(pool), type(uint256).max);
        whbar.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        hbarx.approve(address(vault), type(uint256).max);
        uint256 s = vault.deposit(amt, who);
        vm.stopPrank();
        return s;
    }

    /// Classic first-depositor / donation inflation attack must not strip a victim.
    function test_inflationAttackIsMitigated() public {
        vm.startPrank(alice);
        hbarx.approve(address(vault), type(uint256).max);
        vault.deposit(1, alice);
        hbarx.transfer(address(vault), 500e8);     // donate to inflate
        vm.stopPrank();

        uint256 shares = _deposit(bob, 100e8);
        assertGt(shares, 0, "victim got no shares");
        assertGt(vault.previewRedeem(shares), 99e8, "victim lost too much");
    }

    /// With no debt, NAV must not consult a price at all.
    function test_noDebtNeedsNoOracle() public {
        _deposit(alice, 100e8);
        oracle.setBroken(true);
        assertEq(vault.totalAssets(), 100e8);
        vm.prank(alice);
        vault.withdraw(50e8, alice, alice);
        assertEq(hbarx.balanceOf(alice), 950e8);
    }

    /// With debt, a dead oracle must REVERT, never fall back to a guessable price.
    function test_debtWithDeadOracleReverts() public {
        _deposit(alice, 100e8);
        dTok.mint(address(vault), 10e8);
        assertGt(vault.totalAssets(), 0);
        oracle.setBroken(true);
        vm.expectRevert();
        vault.totalAssets();
    }

    /// Moving the AMM must not move the share price.
    function test_ammManipulationDoesNotMoveNav() public {
        _deposit(alice, 100e8);
        dTok.mint(address(vault), 10e8);
        uint256 navBefore = vault.totalAssets();
        pair.setReserves(1e8, 100000e8);
        assertEq(vault.totalAssets(), navBefore, "AMM moved NAV");
    }

    /// Owner must not be able to take user assets.
    function test_ownerCannotSweepUserFunds() public {
        _deposit(alice, 100e8);
        vm.expectRevert(bytes("core token"));
        vault.sweep(address(hbarx), address(this), 100e8);
        vm.expectRevert(bytes("core token"));
        vault.sweep(address(aTok), address(this), 1);
        vm.expectRevert(bytes("core token"));
        vault.sweep(address(dTok), address(this), 1);
    }

    /// Strategy controls are permissioned.
    function test_strategyIsPermissioned() public {
        vm.startPrank(bob);
        vm.expectRevert(bytes("not manager"));
        vault.supplyToPool(0);
        vm.expectRevert(bytes("not manager"));
        vault.leverUp(1, 1e8, 100);
        vm.expectRevert(bytes("not manager"));
        vault.deleverage(1, 1e8, 100);
        vm.stopPrank();
    }

    /// Deposits pause; exits never do.
    function test_pauseBlocksDepositsNotExits() public {
        _deposit(alice, 100e8);
        vault.pause();
        vm.startPrank(alice);
        vm.expectRevert();
        vault.deposit(1e8, alice);
        vault.withdraw(50e8, alice, alice);       // exit still allowed
        vm.stopPrank();
        assertEq(hbarx.balanceOf(alice), 950e8);
    }

    /// Round trip must not leak value.
    function test_roundTripConservesValue() public {
        uint256 start = hbarx.balanceOf(alice);
        uint256 shares = _deposit(alice, 100e8);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(hbarx.balanceOf(alice), start, "value leaked on round trip");
    }

    /// Loop bounds are enforced.
    function test_loopBoundsEnforced() public {
        vm.expectRevert(bytes("loops"));
        vault.leverUp(6, 1e8, 100);
        vm.expectRevert(bytes("params"));
        vault.leverUp(1, 1e8, 3000);              // slippage > 20%
    }

    /// Withdrawals pull from collateral when idle is short.
    function test_withdrawPullsFromCollateral() public {
        _deposit(alice, 100e8);
        vault.supplyToPool(0);                    // everything into the pool
        assertEq(hbarx.balanceOf(address(vault)), 0);
        vm.prank(alice);
        vault.withdraw(40e8, alice, alice);       // must unwind collateral
        assertEq(hbarx.balanceOf(alice), 940e8);
    }
}

contract VaultInvariantTest is Test {
    MockToken hbarx; MockToken whbar; MockToken aTok; MockToken dTok;
    MockPool pool; MockOracle oracle; MockPair pair;
    HbarxLoopVault vault;

    function setUp() public {
        hbarx = new MockToken("HBARX", 8); whbar = new MockToken("WHBAR", 8);
        aTok = new MockToken("aHBARX", 8); dTok = new MockToken("dWHBAR", 8);
        pool = new MockPool(hbarx, aTok, dTok, whbar);
        oracle = new MockOracle();
        pair = new MockPair(address(whbar), address(hbarx), 1000e8, 700e8);
        oracle.set(address(whbar), 1e18); oracle.set(address(hbarx), 1.43e18);
        vault = new HbarxLoopVault(IERC20(address(hbarx)), address(pool), address(pair),
            address(whbar), address(0), address(aTok), address(dTok), address(oracle), address(0));
        vm.startPrank(address(vault));
        hbarx.approve(address(pool), type(uint256).max);
        whbar.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// A depositor must never be able to redeem more than they put in
    /// (no free value), across the whole input range.
    function testFuzz_depositRedeemNeverProfits(uint96 amount) public {
        amount = uint96(bound(amount, 1e4, 1e14));
        address u = address(0xBEEF);
        hbarx.mint(u, amount);
        vm.startPrank(u);
        hbarx.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(amount, u);
        uint256 out = vault.redeem(shares, u, u);
        vm.stopPrank();
        assertLe(out, amount, "depositor extracted more than deposited");
    }

    /// Two depositors must not be able to dilute each other.
    function testFuzz_twoDepositorsFairShare(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1e6, 1e13));
        b = uint96(bound(b, 1e6, 1e13));
        address u1 = address(0x1111); address u2 = address(0x2222);
        hbarx.mint(u1, a); hbarx.mint(u2, b);

        vm.startPrank(u1); hbarx.approve(address(vault), type(uint256).max);
        uint256 s1 = vault.deposit(a, u1); vm.stopPrank();
        vm.startPrank(u2); hbarx.approve(address(vault), type(uint256).max);
        uint256 s2 = vault.deposit(b, u2); vm.stopPrank();

        uint256 o1 = vault.previewRedeem(s1);
        uint256 o2 = vault.previewRedeem(s2);
        // Each recovers essentially their own stake (rounding only).
        assertApproxEqRel(o1, a, 1e15, "u1 diluted");   // 0.1% tolerance
        assertApproxEqRel(o2, b, 1e15, "u2 diluted");
    }

    /// totalAssets must equal idle + collateral whenever there is no debt.
    function testFuzz_navIdentityNoDebt(uint96 d, uint96 supplied) public {
        d = uint96(bound(d, 1e6, 1e13));
        address u = address(0xCAFE);
        hbarx.mint(u, d);
        vm.startPrank(u); hbarx.approve(address(vault), type(uint256).max);
        vault.deposit(d, u); vm.stopPrank();

        uint256 toSupply = bound(supplied, 0, d);
        if (toSupply > 0) vault.supplyToPool(toSupply);

        assertEq(vault.totalAssets(),
            hbarx.balanceOf(address(vault)) + aTok.balanceOf(address(vault)),
            "NAV identity broken");
    }
}
