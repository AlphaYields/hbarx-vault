// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/*
  HbarxLoopVault — ERC-4626 vault for the HBARX/WHBAR leverage loop on Hedera.

  Accepts BOTH native HBAR and HBARX as deposits. HBAR is converted to HBARX on
  the way in: by staking through Stader where a staking contract is configured
  (protocol rate, no slippage), otherwise by swapping on SaucerSwap. Withdrawals
  are in HBARX.

  The ERC-4626 core — share conversion, rounding, first-depositor inflation
  protection, ERC-20 behaviour — is OpenZeppelin's, inherited unmodified. This
  file adds the Hedera handling and the strategy.

  ─ NAV and pricing ──────────────────────────────────────────────────────────
  With no debt, net assets are idle + collateral and no price is consulted at
  all. Once debt exists it is valued ONLY by the lending market's own oracle —
  the same oracle that decides liquidation — and totalAssets() reverts if that
  oracle is unavailable. An AMM spot price is never used for share pricing,
  because it can be moved within a block. Reverting is deliberate: a vault that
  cannot price itself must not mint or burn shares. It is not a lock-in, since
  deleverage() reads balances only and can always unwind back to zero debt.

  ─ Hedera specifics ─────────────────────────────────────────────────────────
  * Every external address must be the target's EVM ALIAS. A Hedera contract
    called at its long-zero address from inside another contract returns success
    with EMPTY return data, so abi.decode reverts.
  * HTS tokens must be associated before they can be held (HIP-719). This cannot
    happen in the constructor, and HIP-904 auto-association only fires on first
    receipt — too late for approve(). Hence associate().
  * HTS approve() rejects large values: uint256.max and int64.max both revert.
    The accepted ceiling measured between 1e17 and 1e18.
  * Native HBAR value semantics differ from Ethereum, so every HBAR and HTS
    movement is measured by balance delta rather than trusted from the input.
  * Loop iterations are capped for the child-transaction limit.
*/

interface IHRC719 { function associate() external returns (uint256); }

interface IWHBAR {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 ref) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 rateMode, uint16 ref, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool use) external;
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateral, uint256 totalDebt, uint256 availableBorrows,
        uint256 liquidationThreshold, uint256 ltv, uint256 healthFactor);
}

interface IPriceOracle { function getAssetPrice(address asset) external view returns (uint256); }

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 a0Out, uint256 a1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

/// Stader liquid staking: stake HBAR, receive HBARX at the protocol rate.
interface IStaking {
    function stake() external payable;
    function getExchangeRate() external view returns (uint256);
}

contract HbarxLoopVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────── immutable
    ILendingPool public immutable pool;
    IPair        public immutable pair;        // EVM alias, never long-zero
    IERC20       public immutable whbar;       // borrowed asset
    IWHBAR       public immutable whbarWrapper;// HBAR <-> WHBAR
    IERC20       public immutable aToken;      // Bonzo collateral receipt
    IERC20       public immutable debtToken;   // Bonzo variable debt

    uint256 private constant VARIABLE_RATE = 2;
    uint8   public  constant MAX_LOOPS     = 5;
    uint256 private constant HTS_MAX       = 1e17;   // HTS approve ceiling
    uint16  private constant MAX_SLIPPAGE  = 2000;   // 20%

    // ───────────────────────────────────────────────────────────────── mutable
    IPriceOracle public oracle;      // lending-market oracle; required once debt exists
    IStaking     public staking;     // optional: HBAR -> HBARX at protocol rate
    address      public keeper;      // may run the loop alongside the owner
    uint16       public swapFeeNum = 997;  // 0.30% pool fee, of 1000
    bool         public associated;

    event Associated();
    event DepositedHBAR(address indexed caller, address indexed receiver, uint256 hbarIn, uint256 assetsOut, uint256 shares);
    event Supplied(uint256 amount);
    event Freed(uint256 amount);
    event Levered(uint8 loops, uint256 supplied, uint256 borrowed);
    event Deleveraged(uint8 loops, uint256 repaid);
    event OracleSet(address oracle);
    event StakingSet(address staking);
    event KeeperSet(address keeper);

    modifier onlyManager() {
        require(msg.sender == owner() || msg.sender == keeper, "not manager");
        _;
    }

    constructor(
        IERC20 _hbarx,
        address _pool,
        address _pair,
        address _whbar,
        address _whbarWrapper,
        address _aToken,
        address _debtToken,
        address _oracle,
        address _staking
    )
        ERC4626(_hbarx)
        ERC20("AlphaYields HBARX Loop Vault", "ayHBARX")
        Ownable(msg.sender)
    {
        require(_pool != address(0) && _pair != address(0) && _whbar != address(0), "zero addr");
        require(_aToken != address(0) && _debtToken != address(0), "zero addr");
        pool = ILendingPool(_pool);
        pair = IPair(_pair);
        whbar = IERC20(_whbar);
        whbarWrapper = IWHBAR(_whbarWrapper);
        aToken = IERC20(_aToken);
        debtToken = IERC20(_debtToken);
        oracle = IPriceOracle(_oracle);
        staking = IStaking(_staking);
        // No HTS approve() here: it reverts in a constructor, the contract is not
        // associated yet. Deferred to associate().
    }

    receive() external payable {}

    // ──────────────────────────────────────────────────────────── Hedera setup
    /// Associate the HTS tokens this vault holds and approve the lending pool.
    /// Permissionless and idempotent; must run once before the first deposit.
    function associate() external {
        require(!associated, "done");
        IHRC719(asset()).associate();
        IHRC719(address(whbar)).associate();
        associated = true;
        IERC20(asset()).forceApprove(address(pool), HTS_MAX);
        whbar.forceApprove(address(pool), HTS_MAX);
        emit Associated();
    }

    /// Top the pool allowances back up if they are ever drawn down.
    function refreshApprovals() external {
        require(associated, "associate first");
        IERC20(asset()).forceApprove(address(pool), HTS_MAX);
        whbar.forceApprove(address(pool), HTS_MAX);
    }

    // ────────────────────────────────────────────────────────────── accounting
    /// OpenZeppelin defaults this to 0, which leaves the first-depositor /
    /// donation inflation attack viable: a tiny first deposit plus a large direct
    /// transfer can round a later depositor's shares down to zero. A non-zero
    /// offset scales the virtual share reserve and makes the attack require
    /// ~10^OFFSET times more capital than it can extract. Verified by
    /// test_inflationAttackIsMitigated.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// Idle + collateral, less debt valued by the lending oracle.
    /// Reverts when debt exists and the oracle cannot price it — see header.
    function totalAssets() public view override returns (uint256) {
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + aToken.balanceOf(address(this));
        uint256 debt = debtToken.balanceOf(address(this));
        if (debt == 0) return gross;

        require(address(oracle) != address(0), "no oracle");
        uint256 pW = oracle.getAssetPrice(address(whbar));
        uint256 pA = oracle.getAssetPrice(asset());
        require(pW > 0 && pA > 0, "bad price");

        uint256 debtInAsset = (debt * pW) / pA;
        return gross > debtInAsset ? gross - debtInAsset : 0;
    }

    /// Only what the vault can actually hand over right now.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 ceiling = super.maxWithdraw(owner_);
        uint256 liquid = IERC20(asset()).balanceOf(address(this)) + aToken.balanceOf(address(this));
        return ceiling < liquid ? ceiling : liquid;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 shares = super.maxRedeem(owner_);
        uint256 viaAssets = _convertToShares(maxWithdraw(owner_), Math.Rounding.Floor);
        return shares < viaAssets ? shares : viaAssets;
    }

    // ──────────────────────────────────────────────────────────────── deposits
    function deposit(uint256 assets, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// Deposit native HBAR. Converted to HBARX by staking where available,
    /// otherwise swapped on the pair. `minAssetsOut` bounds the conversion.
    function depositHBAR(address receiver, uint256 minAssetsOut)
        external payable nonReentrant whenNotPaused returns (uint256 shares)
    {
        require(msg.value > 0, "zero");
        require(receiver != address(0), "zero receiver");

        uint256 assetsBefore = IERC20(asset()).balanceOf(address(this));
        _hbarToAsset(msg.value);
        uint256 assets = IERC20(asset()).balanceOf(address(this)) - assetsBefore;
        require(assets >= minAssetsOut && assets > 0, "slippage");

        // Price shares against the state BEFORE these assets arrived.
        uint256 supply = totalSupply();
        if (supply == 0) {
            shares = assets;
        } else {
            uint256 totalAfter = totalAssets();
            uint256 totalBefore = totalAfter > assets ? totalAfter - assets : 0;
            shares = totalBefore == 0 ? assets : (assets * supply) / totalBefore;
        }
        require(shares > 0, "no shares");
        _mint(receiver, shares);
        emit DepositedHBAR(msg.sender, receiver, msg.value, assets, shares);
    }

    /// Convert native HBAR into the vault's asset.
    function _hbarToAsset(uint256 hbarAmount) internal {
        if (address(staking) != address(0)) {
            staking.stake{value: hbarAmount}();   // protocol rate, no slippage
            return;
        }
        // Fallback: wrap to WHBAR, then swap on the pair.
        uint256 wBefore = whbar.balanceOf(address(this));
        whbarWrapper.deposit{value: hbarAmount}();
        uint256 wGot = whbar.balanceOf(address(this)) - wBefore;
        require(wGot > 0, "wrap failed");
        _swap(address(whbar), wGot, 0);   // bounded by minAssetsOut upstream
    }

    // ─────────────────────────────────────────────────────────────── withdraw
    function withdraw(uint256 assets, address receiver, address owner_)
        public override nonReentrant returns (uint256)
    {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public override nonReentrant returns (uint256)
    {
        return super.redeem(shares, receiver, owner_);
    }

    /// Serve withdrawals from idle, topping up from collateral when needed.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal override
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            uint256 need = assets - idle;
            uint256 coll = aToken.balanceOf(address(this));
            if (need > coll) need = coll;
            if (need > 0) {
                pool.withdraw(asset(), need, address(this));
                emit Freed(need);
            }
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────── strategy
    function supplyToPool(uint256 amount) public onlyManager {
        if (amount == 0) amount = IERC20(asset()).balanceOf(address(this));
        require(amount > 0, "nothing");
        pool.deposit(asset(), amount, address(this), 0);
        emit Supplied(amount);
    }

    function withdrawFromPool(uint256 amount) external onlyManager {
        pool.withdraw(asset(), amount, address(this));
        emit Freed(amount);
    }

    function enableCollateral() external onlyManager {
        pool.setUserUseReserveAsCollateral(asset(), true);
    }

    /// Supply idle, borrow `borrowPerLoop` WHBAR, swap to HBARX, repeat.
    /// Sizing is decided off-chain; slippageBps bounds each swap.
    function leverUp(uint8 loops, uint256 borrowPerLoop, uint16 slippageBps)
        external onlyManager nonReentrant
    {
        require(loops > 0 && loops <= MAX_LOOPS, "loops");
        require(borrowPerLoop > 0 && slippageBps <= MAX_SLIPPAGE, "params");
        uint256 supplied;
        uint256 borrowed;

        for (uint8 i = 0; i < loops; i++) {
            uint256 idle = IERC20(asset()).balanceOf(address(this));
            if (idle > 0) { pool.deposit(asset(), idle, address(this), 0); supplied += idle; }

            uint256 wBefore = whbar.balanceOf(address(this));
            pool.borrow(address(whbar), borrowPerLoop, VARIABLE_RATE, 0, address(this));
            uint256 got = whbar.balanceOf(address(this)) - wBefore;
            if (got == 0) break;
            borrowed += got;

            uint256 expected = quoteWhbarToAsset(got);
            _swap(address(whbar), got, (expected * (10000 - slippageBps)) / 10000);
        }
        emit Levered(loops, supplied, borrowed);
    }

    /// Withdraw collateral, swap to WHBAR, repay. Reads balances only, so it
    /// keeps working when totalAssets() cannot price itself.
    function deleverage(uint8 loops, uint256 withdrawPerLoop, uint16 slippageBps)
        external onlyManager nonReentrant
    {
        require(loops > 0 && loops <= MAX_LOOPS, "loops");
        require(slippageBps <= MAX_SLIPPAGE, "params");
        uint256 repaid;

        for (uint8 i = 0; i < loops; i++) {
            uint256 debt = debtToken.balanceOf(address(this));
            if (debt == 0) break;
            uint256 coll = aToken.balanceOf(address(this));
            if (coll == 0) break;

            uint256 pull = withdrawPerLoop > coll ? coll : withdrawPerLoop;
            pool.withdraw(asset(), pull, address(this));

            uint256 have = IERC20(asset()).balanceOf(address(this));
            if (have == 0) break;
            uint256 expected = quoteAssetToWhbar(have);
            uint256 got = _swap(asset(), have, (expected * (10000 - slippageBps)) / 10000);

            uint256 amt = got > debt ? debt : got;
            pool.repay(address(whbar), amt, VARIABLE_RATE, address(this));
            repaid += amt;
        }
        emit Deleveraged(loops, repaid);
    }

    // ─────────────────────────────────────────────────────────────────── swaps
    function _reserves() internal view returns (uint256 rW, uint256 rA) {
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        return pair.token0() == address(whbar) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _out(uint256 amtIn, uint256 rIn, uint256 rOut) internal view returns (uint256) {
        require(rIn > 0 && rOut > 0, "no liquidity");
        uint256 inFee = amtIn * swapFeeNum;
        return (inFee * rOut) / (rIn * 1000 + inFee);
    }

    function quoteWhbarToAsset(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, w, x); }
    function quoteAssetToWhbar(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, x, w); }

    /// Constant-product swap straight against the pair, verified by balance delta.
    function _swap(address tokenIn, uint256 amtIn, uint256 minOut) internal returns (uint256 out) {
        bool inIsWhbar = tokenIn == address(whbar);
        (uint256 rW, uint256 rA) = _reserves();
        uint256 expected = inIsWhbar ? _out(amtIn, rW, rA) : _out(amtIn, rA, rW);
        require(expected >= minOut && expected > 0, "slippage");

        IERC20(tokenIn).safeTransfer(address(pair), amtIn);
        bool t0IsWhbar = pair.token0() == address(whbar);
        (uint256 a0, uint256 a1) = inIsWhbar
            ? (t0IsWhbar ? (uint256(0), expected) : (expected, uint256(0)))
            : (t0IsWhbar ? (expected, uint256(0)) : (uint256(0), expected));

        IERC20 outTok = inIsWhbar ? IERC20(asset()) : whbar;
        uint256 before = outTok.balanceOf(address(this));
        pair.swap(a0, a1, address(this), "");
        out = outTok.balanceOf(address(this)) - before;
        require(out >= minOut, "out short");
    }

    // ──────────────────────────────────────────────────────────────────── views
    function position() external view returns (uint256 collateral, uint256 debt, uint256 idle, uint256 nav) {
        collateral = aToken.balanceOf(address(this));
        debt = debtToken.balanceOf(address(this));
        idle = IERC20(asset()).balanceOf(address(this));
        nav = debt == 0 ? idle + collateral : totalAssets();
    }

    function healthFactor() external view returns (uint256 hf) {
        (, , , , , hf) = pool.getUserAccountData(address(this));
    }

    // ──────────────────────────────────────────────────────────────────── admin
    function setOracle(address v) external onlyOwner { oracle = IPriceOracle(v); emit OracleSet(v); }
    function setStaking(address v) external onlyOwner { staking = IStaking(v); emit StakingSet(v); }
    function setKeeper(address v) external onlyOwner { keeper = v; emit KeeperSet(v); }
    function setSwapFeeNum(uint16 v) external onlyOwner { require(v >= 950 && v <= 1000, "range"); swapFeeNum = v; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover stray tokens. Can never touch the asset, collateral or debt
    /// positions, so the owner cannot withdraw user funds.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        require(token != asset() && token != address(aToken) && token != address(debtToken), "core token");
        require(to != address(0), "zero to");
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "hbar send");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
