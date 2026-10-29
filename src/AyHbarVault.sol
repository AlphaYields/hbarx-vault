// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultMath} from "./VaultMath.sol";

/*
  ayHBAR — ERC-4626 vault for leveraged HBAR staking on Hedera.

  Deposit HBAR or HBARX, receive ayHBAR shares. Deposited capital is staked as
  HBARX, supplied to a lending market as collateral, and optionally levered by
  borrowing HBAR and restaking it.

  The ERC-4626 core is OpenZeppelin's, inherited unmodified. This file adds the
  Hedera handling, the strategy, fees, roles and the withdrawal queue.

  ─ Roles ───────────────────────────────────────────────────────────────────
    owner     configuration: fees, roles, timelock, deposit cap, unpause
    guardian  emergency: pause, and unwind leverage
    curator   day-to-day strategy: supply, withdraw, lever, deleverage
  Owner holds every permission its delegates hold.

  ─ Fees ────────────────────────────────────────────────────────────────────
  Performance fee is charged only on gains above the high-water mark, so a
  depositor is never charged twice for recovering the same ground. Management
  fee accrues pro-rata over time on assets under management. Both are taken by
  minting shares to the fee recipient, which dilutes holders proportionally and
  never touches the vault's assets.

  ─ Pausing ─────────────────────────────────────────────────────────────────
  A pause halts deposits and withdrawals alike. Unwinding leverage stays
  available throughout, so a position can always be brought back to safety
  while the vault is paused. Only the owner can lift a pause.

  ─ Withdrawal queue ────────────────────────────────────────────────────────
  While a timelock is set, exiting is a two-step flow: request, wait, then
  withdraw or redeem. Requested shares are escrowed in the vault so they cannot
  be transferred away while queued, but they remain in totalSupply and keep
  earning until the moment they are burned. Setting the timelock to zero makes
  exits immediate.

  ─ Pricing ─────────────────────────────────────────────────────────────────
  With no debt outstanding, net assets are idle + collateral and no price is
  consulted at all. Once debt exists it is valued at the staking protocol's
  redemption rate, cross-checked against the lending market's oracle; the two
  must agree within a bound or pricing refuses to answer. A pool quote never
  sets the share price, and no single source can move it alone.

  ─ Routing ─────────────────────────────────────────────────────────────────
  HBAR entering the vault is converted by whichever route pays more: minting at
  the staking protocol's rate, or buying on one of the registered pools. Both
  are quoted first, and if staking is unavailable the deposit takes a pool
  instead. The same comparison governs the leverage loop.

  ─ Arbitrage ───────────────────────────────────────────────────────────────
  When two venues price the asset differently the curator can sell on one and
  buy back on the other, or sell and mint back through the staking protocol.
  Both legs settle in one transaction and the vault must end holding more of
  its asset than it started with, so the operation can only add.

  ─ Swap bounds ─────────────────────────────────────────────────────────────
  Every swap is floored against the redemption rate rather than the pool's own
  reserves, so the bound holds whether the pool has been pushed or the trade is
  simply too large for it.

  ─ Hedera ──────────────────────────────────────────────────────────────────
  HTS tokens must be associated before they can be held and cannot be approved
  from a constructor; HTS approve() rejects very large values; external calls
  must target a contract's EVM alias. All handled below.
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

/// Uniswap-V3-style router, as SaucerSwap V2 exposes it.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IStaking {
    function stake() external payable;
    function getExchangeRate() external view returns (uint256);
}

contract AyHbarVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ───────────────────────────────────────────────────────────── constants
    uint256 private constant BPS            = 10_000;
    uint256 private constant MAX_PERF_FEE   = 5_000;   // 50%
    uint256 private constant MAX_MGMT_FEE   = 500;     // 5%
    uint256 private constant MAX_TIMELOCK   = 30 days;
    uint256 private constant VARIABLE_RATE  = 2;
    uint256 private constant HTS_MAX        = 1e17;    // HTS approve ceiling
    uint8   private constant MAX_LOOPS      = 5;
    uint16  private constant MAX_SLIPPAGE   = 500;     // 5% hard ceiling
    uint8   private constant MAX_VENUES     = 8;
    uint16  private constant MAX_DEVIATION  = 500;     // 5% oracle disagreement ceiling
    uint256 private constant HF_ONE         = 1e18;
    /// Passed as `buyVenue` to route the second leg through staking.
    uint256 private constant STAKE_ROUTE     = type(uint256).max;

    // ───────────────────────────────────────────────────────────── immutable
    ILendingPool public immutable pool;
    IPair        public immutable pair;
    IERC20       public immutable whbar;
    IWHBAR       public immutable whbarWrapper;
    IERC20       public immutable aToken;
    IERC20       public immutable debtToken;

    // ───────────────────────────────────────────────────────────────── roles
    address public guardian;
    address public curator;

    // ────────────────────────────────────────────────────────────────── fees
    uint16  public performanceFee = 2_000;   // 20%
    uint16  public managementFee;            // 0%
    address public feeRecipient;
    uint256 public highWaterMark;            // assets per 1e18 shares
    uint64  public lastFeeAccrual;

    // ───────────────────────────────────────────────────────────── liquidity
    uint256 public depositCap = type(uint256).max;
    uint64  public withdrawTimelock;

    struct WithdrawRequest { uint256 shares; uint64 unlockAt; }
    mapping(address => WithdrawRequest) public withdrawRequests;
    uint256 public totalQueuedShares;

    // ─────────────────────────────────────────────────────── strategy config
    IPriceOracle public oracle;
    IStaking     public staking;
    uint16       public maxSlippageBps = 100;   // 1% operating limit, owner-settable
    bool         public associated;

    /// Oracle disagreement tolerated before pricing refuses to answer, in bps.
    uint16 public maxOracleDeviationBps = 100;   // 1%
    /// Health factor the vault keeps while levered, 1e18-scaled.
    uint256 public minHealthFactor = 1.4e18;
    /// Health factor below which anyone may unwind leverage.
    uint256 public unwindHealthFactor = 1.15e18;
    /// Router used for concentrated-liquidity venues.
    address public swapRouter;

    /// Pools the vault may route through. Several may be registered: deposits
    /// take whichever quotes best, and the difference between two of them is
    /// what makes a cross-venue trade worth doing.
    VaultMath.Venue[] public venues;

    // ──────────────────────────────────────────────────────────────── events
    event DepositedHBAR(address indexed caller, address indexed receiver, uint256 hbarIn, uint256 assets, uint256 shares);
    event WithdrawRequested(address indexed owner, uint256 shares, uint64 unlockAt);
    event WithdrawRequestCancelled(address indexed owner, uint256 shares);
    event FeesAccrued(uint256 performanceAssets, uint256 managementAssets, uint256 sharesMinted);
    event Levered(uint8 loops, uint256 supplied, uint256 borrowed);
    event Deleveraged(uint8 loops, uint256 repaid);
    event RoleSet(bytes32 indexed role, address account);
    event FeesSet(uint16 performanceFee, uint16 managementFee, address feeRecipient);
    event DepositCapSet(uint256 cap);
    event WithdrawTimelockSet(uint64 seconds_);
    event StrategyConfigured(address oracle, address staking, uint16 slippageBps,
                             uint16 deviationBps, uint256 minHealthFactor, uint256 unwindHealthFactor);
    event VenueSet(uint256 indexed index, address pair, bool active);
    event SwapRouterSet(address router);
    event Routed(bool viaStaking, uint256 venueIndex, uint256 amountIn, uint256 assetsOut);
    event Arbitraged(uint256 sellVenue, uint256 buyVenue, uint256 amountIn, uint256 profit);


    error NotAuthorized();
    error CapExceeded();
    error NoMaturedRequest();
    error TimelockNotElapsed();
    error InvalidParam();
    error PriceUnavailable();
    error OracleDisagreement();
    error UnhealthyPosition();
    error NoProfit();

    modifier onlyCurator() {
        if (msg.sender != curator && msg.sender != owner()) revert NotAuthorized();
        _;
    }
    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(
        IERC20 _hbarx, address _pool, address _pair, address _whbar, address _whbarWrapper,
        address _aToken, address _debtToken, address _oracle, address _staking, address _feeRecipient
    )
        ERC4626(_hbarx)
        ERC20("AlphaYields HBAR Vault", "ayHBAR")
        Ownable(msg.sender)
    {
        if (_pool == address(0) || _pair == address(0) || _whbar == address(0)) revert InvalidParam();
        if (_aToken == address(0) || _debtToken == address(0)) revert InvalidParam();
        pool = ILendingPool(_pool);
        pair = IPair(_pair);
        whbar = IERC20(_whbar);
        whbarWrapper = IWHBAR(_whbarWrapper);
        aToken = IERC20(_aToken);
        debtToken = IERC20(_debtToken);
        oracle = IPriceOracle(_oracle);
        staking = IStaking(_staking);
        venues.push(VaultMath.Venue({pair: _pair, feeNum: 997, active: true, kind: 0}));
        feeRecipient = _feeRecipient == address(0) ? msg.sender : _feeRecipient;
        highWaterMark = _pricePerShare(0, 0);   // scale-consistent starting mark
        lastFeeAccrual = uint64(block.timestamp);
    }

    receive() external payable {}

    // ════════════════════════════════════════════════════════════ Hedera setup
    /// Associate the HTS tokens this vault holds, then approve the lending pool.
    /// Permissionless, runs once, and must run before the first deposit.
    /// `refreshApprovals()` tops the allowances up again later.
    function associate() external {
        if (!associated) {
            IHRC719(asset()).associate();
            IHRC719(address(whbar)).associate();
            associated = true;
        }
        // Allowances are consumed as the pool draws on them, so every call
        // tops them back up. Safe to run at any time.
        IERC20(asset()).forceApprove(address(pool), HTS_MAX);
        whbar.forceApprove(address(pool), HTS_MAX);
    }

    // ═══════════════════════════════════════════════════════════════════ fees
    /// Mint fee shares for the period since the last accrual. Safe to call at
    /// any time; it is called automatically before every deposit and withdrawal.
    function accrueFees() public {
        uint256 ts = totalSupply();
        if (ts == 0) { lastFeeAccrual = uint64(block.timestamp); return; }

        uint256 ta = totalAssets();
        (uint256 perfAssets, uint256 mgmtAssets, uint256 shares) = VaultMath.feeAccrual(
            ta, ts, highWaterMark, _pricePerShare(ta, ts), performanceFee, managementFee,
            block.timestamp - lastFeeAccrual, 10 ** _decimalsOffset());

        if (shares > 0 && feeRecipient != address(0)) _mint(feeRecipient, shares);

        lastFeeAccrual = uint64(block.timestamp);
        uint256 newPps = _pricePerShare(totalAssets(), totalSupply());
        if (newPps > highWaterMark) highWaterMark = newPps;
        if (shares > 0 || perfAssets + mgmtAssets > 0) emit FeesAccrued(perfAssets, mgmtAssets, shares);
    }

    function _pricePerShare(uint256 ta, uint256 ts) internal pure returns (uint256) {
        return VaultMath.pricePerShare(ta, ts, 10 ** _decimalsOffset());
    }

    /// Current share price, in assets per whole share. Starts at 1.0 and rises.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    // ════════════════════════════════════════════════════════════ accounting
    /// OpenZeppelin defaults this to 0, which leaves the first-depositor
    /// donation attack viable. A non-zero offset makes the attack uneconomic.
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    /// The staking protocol's redemption rate, or zero when unavailable.
    function _stakingRate() internal view returns (uint256) {
        (bool ok, uint256 r) = VaultMath.tryUint(
            address(staking), abi.encodeWithSelector(IStaking.getExchangeRate.selector));
        return ok ? r : 0;
    }

    /// WHBAR per whole HBARX, 1e8-scaled.
    ///
    /// The staking protocol's redemption rate is the anchor: it is set by the
    /// staking contract, moves only as rewards accrue, and cannot be pushed by
    /// trading. The lending oracle is consulted as a second opinion and the two
    /// must agree within `maxOracleDeviationBps`, so neither source can move the
    /// share price on its own. A market quote is never used here.
    function assetPriceInWhbar() public view returns (uint256) {
        (uint256 price, bool available, bool agrees) = VaultMath.priceInWhbar(
            address(staking), address(oracle), asset(), address(whbar), maxOracleDeviationBps);
        if (!available) revert PriceUnavailable();
        if (!agrees) revert OracleDisagreement();
        return price;
    }

    /// WHBAR converted into asset units at the anchored rate.
    function _whbarToAsset(uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulDiv(1e8, assetPriceInWhbar(), rounding);
    }

    /// Asset units converted into WHBAR at the anchored rate.
    function _assetToWhbar(uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulDiv(assetPriceInWhbar(), 1e8, rounding);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + aToken.balanceOf(address(this));
        uint256 debt = debtToken.balanceOf(address(this));
        uint256 loose = whbar.balanceOf(address(this));
        if (debt == 0 && loose == 0) return gross;

        // Any WHBAR sitting in the vault is an asset; debt is a liability. Both
        // are converted at the anchored rate, debt rounded against the vault.
        gross += _whbarToAsset(loose, Math.Rounding.Floor);
        uint256 debtInAsset = _whbarToAsset(debt, Math.Rounding.Ceil);
        return gross > debtInAsset ? gross - debtInAsset : 0;
    }

    /// Assets the vault could hand over right now.
    ///
    /// With debt outstanding the lending market releases collateral only while
    /// the position stays healthy, so the freeable amount is what can be
    /// withdrawn while keeping the health factor at or above `minHealthFactor`
    /// — not the whole collateral balance.
    function liquidAssets() internal view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 coll = aToken.balanceOf(address(this));
        if (coll == 0) return idle;
        if (debtToken.balanceOf(address(this)) == 0) return idle + coll;
        return idle + _freeableCollateral(coll);
    }

    function _freeableCollateral(uint256 coll) internal view returns (uint256) {
        return VaultMath.freeableCollateral(address(pool), address(this), coll, minHealthFactor);
    }

    /// Current health factor reported by the lending market, 1e18-scaled.
    function healthFactor() internal view returns (uint256 hf) {
        (, , , , , hf) = pool.getUserAccountData(address(this));
    }

    // ═════════════════════════════════════════════════════════════ ERC-4626 caps
    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == type(uint256).max) return type(uint256).max;   // no cap set
        uint256 ta = totalAssets();
        return ta >= depositCap ? 0 : depositCap - ta;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? type(uint256).max : _convertToShares(assets, Math.Rounding.Floor);
    }

    /// With a timelock set, only a matured request can be withdrawn.
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 shares;
        if (withdrawTimelock == 0) {
            shares = balanceOf(owner_);
        } else {
            WithdrawRequest memory r = withdrawRequests[owner_];
            // A few seconds of validator timestamp drift is immaterial against a
            // timelock measured in hours or days.
            // forge-lint: disable-next-line(block-timestamp)
            shares = block.timestamp >= r.unlockAt ? r.shares : 0;
        }
        uint256 byLiquidity = _convertToShares(liquidAssets(), Math.Rounding.Floor);
        return shares < byLiquidity ? shares : byLiquidity;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return _convertToAssets(maxRedeem(owner_), Math.Rounding.Floor);
    }

    // ═══════════════════════════════════════════════════════════════ deposits
    function deposit(uint256 assets, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        accrueFees();
        if (assets > maxDeposit(receiver)) revert CapExceeded();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        accrueFees();
        if (shares > maxMint(receiver)) revert CapExceeded();
        return super.mint(shares, receiver);
    }

    /// Deposit native HBAR. Staked to HBARX where a staking contract is set,
    /// otherwise swapped. `minAssetsOut` bounds the conversion.
    function depositHBAR(address receiver, uint256 minAssetsOut)
        external payable nonReentrant whenNotPaused returns (uint256 shares)
    {
        if (msg.value == 0 || receiver == address(0)) revert InvalidParam();
        accrueFees();

        // Check the cap on what this deposit is worth before converting, so the
        // incoming amount is counted once rather than twice.
        // msg.value arrives in tinybar, the same eight-decimal unit the asset
        // and WHBAR use, so no scaling is needed anywhere in this path.
        uint256 headroom = maxDeposit(receiver);
        if (headroom != type(uint256).max) {
            uint256 expectedAssets = _whbarToAsset(msg.value, Math.Rounding.Floor);
            if (expectedAssets > headroom) revert CapExceeded();
        }

        uint256 before = IERC20(asset()).balanceOf(address(this));
        _wrapAndConvert(msg.value, maxSlippageBps);
        uint256 assets = IERC20(asset()).balanceOf(address(this)) - before;
        if (assets < minAssetsOut || assets == 0) revert InvalidParam();
        if (assets > maxDeposit(receiver)) revert CapExceeded();

        // Price against the state before these assets landed.
        shares = VaultMath.sharesForArrivedAssets(
            assets, totalSupply(), totalAssets(), 10 ** _decimalsOffset());
        if (shares == 0) revert InvalidParam();
        _mint(receiver, shares);
        // The standard event first, so ERC-4626 indexers see every deposit; the
        // second carries the HBAR detail the standard one has no room for.
        emit Deposit(msg.sender, receiver, assets, shares);
        emit DepositedHBAR(msg.sender, receiver, msg.value, assets, shares);
    }

    /// Convert WHBAR into the vault's asset by whichever route pays more.
    ///
    /// Staking mints at the protocol rate with no fee; a pool charges its fee
    /// and moves against the trade, but can still win when it trades at a
    /// discount. Both are quoted and the better one taken. If staking is the
    /// better quote but the call reverts — as it does while the staking entry
    /// is unavailable — the conversion falls through to a pool rather than
    /// failing. Callers holding native HBAR wrap it first, so there is one
    /// path here rather than two.
    function _toAsset(uint256 amount, uint16 slippageBps) internal returns (uint256 got) {
        uint256 rate = _stakingRate();
        uint256 stakingOut = rate > 0 ? amount.mulDiv(1e8, rate, Math.Rounding.Floor) : 0;
        (uint256 venueIndex, uint256 venueOut) = bestVenue(address(whbar), amount);
        uint256 aBefore = IERC20(asset()).balanceOf(address(this));

        if (stakingOut > 0 && stakingOut >= venueOut) {
            uint256 hBefore = address(this).balance;
            whbarWrapper.withdraw(amount);
            uint256 native = address(this).balance - hBefore;
            try staking.stake{value: native}() {
                got = IERC20(asset()).balanceOf(address(this)) - aBefore;
                emit Routed(true, type(uint256).max, amount, got);
                return got;
            } catch {
                whbarWrapper.deposit{value: native}();   // re-wrap and use a pool
            }
        }
        if (venueOut == 0) revert InvalidParam();
        got = _swapAt(venueIndex, address(whbar), amount, slippageBps);
        emit Routed(false, venueIndex, amount, got);
    }

    /// Wrap native HBAR and hand it to the router above.
    function _wrapAndConvert(uint256 hbarAmount, uint16 slippageBps) internal returns (uint256) {
        uint256 wBefore = whbar.balanceOf(address(this));
        whbarWrapper.deposit{value: hbarAmount}();
        uint256 wGot = whbar.balanceOf(address(this)) - wBefore;
        if (wGot == 0) revert InvalidParam();
        return _toAsset(wGot, slippageBps);
    }

    // ══════════════════════════════════════════════════════ withdrawal queue
    /// Queue shares for withdrawal. They are escrowed here until the timelock
    /// elapses, and keep earning until the moment they are burned. Adding to an
    /// existing request restarts the timelock on the whole of it.
    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidParam();
        _transfer(msg.sender, address(this), shares);
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        r.shares += shares;
        r.unlockAt = uint64(block.timestamp) + withdrawTimelock;
        totalQueuedShares += shares;
        emit WithdrawRequested(msg.sender, shares, r.unlockAt);
    }

    /// Take shares back out of the queue at any time.
    function cancelWithdrawRequest() external nonReentrant {
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        uint256 shares = r.shares;
        if (shares == 0) revert InvalidParam();
        delete withdrawRequests[msg.sender];
        totalQueuedShares -= shares;
        _transfer(address(this), msg.sender, shares);
        emit WithdrawRequestCancelled(msg.sender, shares);
    }

    function withdrawableAt(address owner_) external view returns (uint256 shares, uint64 unlockAt) {
        WithdrawRequest memory r = withdrawRequests[owner_];
        return (r.shares, r.unlockAt);
    }

    // ══════════════════════════════════════════════════════════════ withdraw
    function withdraw(uint256 assets, address receiver, address owner_)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        accrueFees();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        accrueFees();
        return super.redeem(shares, receiver, owner_);
    }

    /// Consume a matured request (when a timelock is set), free collateral if
    /// idle is short, then let OpenZeppelin burn and pay out.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal override
    {
        if (withdrawTimelock > 0) {
            WithdrawRequest storage r = withdrawRequests[owner_];
            if (r.shares < shares) revert NoMaturedRequest();
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < r.unlockAt) revert TimelockNotElapsed();
            // Shares are escrowed here, so OpenZeppelin's burn-from-owner path
            // does not run; the allowance check it performs must still happen.
            if (caller != owner_) _spendAllowance(owner_, caller, shares);
            r.shares -= shares;
            if (r.shares == 0) r.unlockAt = 0;
            totalQueuedShares -= shares;
            _burn(address(this), shares);
            _freeForWithdrawal(assets);
            IERC20(asset()).safeTransfer(receiver, assets);
            emit Withdraw(caller, receiver, owner_, assets, shares);
            return;
        }
        _freeForWithdrawal(assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// Make `assets` available to pay a withdrawal.
    ///
    /// Idle balance first, then collateral. While the vault is levered the
    /// lending market releases collateral only to the extent the position stays
    /// healthy, so leverage is unwound first by as much as the shortfall needs —
    /// a withdrawal does not wait on anyone to act manually.
    function _freeForWithdrawal(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        uint256 need = assets - idle;

        if (debtToken.balanceOf(address(this)) > 0) {
            uint256 freeable = _freeableCollateral(aToken.balanceOf(address(this)));
            if (freeable < need) {
                // Unwind in equal steps; each pass repays debt and releases the
                // collateral that was backing it.
                uint256 step = need > freeable ? need - freeable : 0;
                _unwind(MAX_LOOPS, step + freeable, maxSlippageBps);
            }
        }

        idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        need = assets - idle;
        uint256 coll = aToken.balanceOf(address(this));
        if (need > coll) need = coll;
        if (need > 0) pool.withdraw(asset(), need, address(this));
    }

    // ══════════════════════════════════════════════════════════════ strategy
    /// Supply idle assets as collateral. `0` supplies the whole idle balance.
    /// The reserve is marked as collateral on every call, which is idempotent.
    function supplyToPool(uint256 amount) external onlyCurator nonReentrant {
        if (amount == 0) amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) revert InvalidParam();
        pool.deposit(asset(), amount, address(this), 0);
        pool.setUserUseReserveAsCollateral(asset(), true);
    }

    function withdrawFromPool(uint256 amount) external onlyCurator nonReentrant {
        if (amount == 0) amount = aToken.balanceOf(address(this));
        if (amount == 0) revert InvalidParam();
        pool.withdraw(asset(), amount, address(this));
    }

    function leverUp(uint8 loops, uint256 borrowPerLoop, uint16 slippageBps)
        external onlyCurator nonReentrant whenNotPaused
    {
        if (loops == 0 || loops > MAX_LOOPS) revert InvalidParam();
        if (borrowPerLoop == 0 || slippageBps > maxSlippageBps) revert InvalidParam();
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
            _toAsset(got, slippageBps);
        }
        uint256 hf = healthFactor();
        if (hf < minHealthFactor) revert UnhealthyPosition();
        emit Levered(loops, supplied, borrowed);
    }

    function deleverage(uint8 loops, uint256 withdrawPerLoop, uint16 slippageBps)
        external nonReentrant
    {
        if (msg.sender != guardian && msg.sender != owner()
            && healthFactor() >= unwindHealthFactor) revert NotAuthorized();
        if (slippageBps > maxSlippageBps) revert InvalidParam();
        _unwind(loops, withdrawPerLoop, slippageBps);
    }

    /// Withdraw collateral, sell only what the debt needs, repay. Repeated.
    ///
    /// Selling the whole idle balance each pass is what strands WHBAR in the
    /// vault, so the sale is sized to the remaining debt plus the slippage
    /// allowance and no more.
    function _unwind(uint8 loops, uint256 withdrawPerLoop, uint16 slippageBps) internal {
        if (loops == 0 || loops > MAX_LOOPS) revert InvalidParam();
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

            uint256 holding = whbar.balanceOf(address(this));
            if (holding < debt) {
                // Sell only what the shortfall needs, plus the slippage
                // allowance. Selling the whole idle balance is what strands
                // borrowed tokens in the vault with nothing to convert them.
                uint256 sell = _whbarToAsset(debt - holding, Math.Rounding.Ceil)
                                   .mulDiv(BPS + slippageBps, BPS, Math.Rounding.Ceil);
                if (sell > have) sell = have;
                if (sell > 0) {
                    (uint256 v, uint256 q) = bestVenue(asset(), sell);
                    if (q == 0) revert InvalidParam();   // no quotable venue
                    _swapAt(v, asset(), sell, slippageBps);
                }
                holding = whbar.balanceOf(address(this));
            }
            uint256 amt = holding > debt ? debt : holding;
            if (amt == 0) break;
            pool.repay(address(whbar), amt, VARIABLE_RATE, address(this));
            repaid += amt;
        }
        emit Deleveraged(loops, repaid);
    }

    /// Convert WHBAR left in the vault back into the asset.
    ///
    /// Permissionless, routed like any other conversion, and bounded by the
    /// same slippage floor as every other swap: it can only improve the
    /// vault's position, never move value out.
    function recoverWhbar() external nonReentrant returns (uint256) {
        uint256 amount = whbar.balanceOf(address(this));
        if (amount == 0 || debtToken.balanceOf(address(this)) > 0) revert InvalidParam();
        return _toAsset(amount, maxSlippageBps);
    }

    // ════════════════════════════════════════════════════════════ arbitrage
    /// Sell the asset on one venue and buy it back on another.
    ///
    /// Both legs settle in the same transaction and the vault must finish
    /// holding more of its asset than it started with, or the call reverts.
    /// That makes the operation safe by construction: it can add to the vault's
    /// holdings and cannot subtract from them, whatever the pools do in between.
    /// `buyVenue` is a venue index, or `STAKE_ROUTE` to mint the asset back
    /// through the staking protocol instead of buying it on a second pool.
    function arbitrage(uint256 sellVenue, uint256 buyVenue, uint256 amountIn, uint256 minProfit)
        external onlyCurator nonReentrant returns (uint256 profit)
    {
        if (sellVenue == buyVenue) revert InvalidParam();
        uint256 before = IERC20(asset()).balanceOf(address(this));
        if (amountIn == 0 || amountIn > before) revert InvalidParam();

        uint256 whbarOut = _swapAt(sellVenue, asset(), amountIn, maxSlippageBps);
        if (buyVenue == STAKE_ROUTE) {
            uint256 hBefore = address(this).balance;
            whbarWrapper.withdraw(whbarOut);
            staking.stake{value: address(this).balance - hBefore}();
        } else {
            _swapAt(buyVenue, address(whbar), whbarOut, maxSlippageBps);
        }

        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (held <= before) revert NoProfit();
        profit = held - before;
        if (profit < minProfit) revert NoProfit();
        emit Arbitraged(sellVenue, buyVenue, amountIn, profit);
    }

    // ═════════════════════════════════════════════════════════════════ swaps

    /// The venue paying most for a given input, and what it pays.
    function bestVenue(address tokenIn, uint256 amtIn)
        internal view returns (uint256 index, uint256 amountOut)
    {
        return VaultMath.best(venues, address(whbar), tokenIn == address(whbar), amtIn);
    }

    /// Swap through one venue.
    ///
    /// The floor is derived from the anchored rate, not from the pool's own
    /// reserves, so it bounds both a distorted pool and the trade's own price
    /// impact. A quote taken from the same reserves the swap reads would bound
    /// neither.
    function _swapAt(uint256 i, address tokenIn, uint256 amtIn, uint16 slippageBps)
        internal returns (uint256 out)
    {
        if (i >= venues.length || !venues[i].active || amtIn == 0) revert InvalidParam();
        if (slippageBps > maxSlippageBps) revert InvalidParam();

        bool inIsWhbar = tokenIn == address(whbar);
        uint256 fair = inIsWhbar
            ? _whbarToAsset(amtIn, Math.Rounding.Floor)
            : _assetToWhbar(amtIn, Math.Rounding.Floor);
        uint256 floor_ = fair.mulDiv(BPS - slippageBps, BPS, Math.Rounding.Floor);

        IERC20 outTok = inIsWhbar ? IERC20(asset()) : whbar;
        uint256 before = outTok.balanceOf(address(this));

        if (venues[i].kind == 1) {
            // Concentrated liquidity: the router prices the swap and enforces
            // the floor. No quote is needed in advance because the floor comes
            // from the redemption rate rather than from the pool.
            ISwapRouter(swapRouter).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: address(outTok),
                fee: uint24(venues[i].feeNum),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amtIn,
                amountOutMinimum: floor_,
                sqrtPriceLimitX96: 0
            }));
        } else {
            uint256 expected = VaultMath.quote(venues[i], address(whbar), inIsWhbar, amtIn);
            if (expected == 0 || expected < floor_) revert InvalidParam();

            IPair p = IPair(venues[i].pair);
            IERC20(tokenIn).safeTransfer(address(p), amtIn);
            bool t0IsWhbar = p.token0() == address(whbar);
            (uint256 a0, uint256 a1) = inIsWhbar
                ? (t0IsWhbar ? (uint256(0), expected) : (expected, uint256(0)))
                : (t0IsWhbar ? (expected, uint256(0)) : (uint256(0), expected));
            p.swap(a0, a1, address(this), "");
        }

        out = outTok.balanceOf(address(this)) - before;
        if (out < floor_) revert InvalidParam();
    }

    // ═════════════════════════════════════════════════════════════════ views
    // ═════════════════════════════════════════════════════════════════ admin
    /// Set both delegate roles. Passing the zero address clears one.
    function setRoles(address guardian_, address curator_) external onlyOwner {
        guardian = guardian_;
        curator = curator_;
        emit RoleSet("guardian", guardian_);
        emit RoleSet("curator", curator_);
    }

    function setFees(uint16 perf, uint16 mgmt, address recipient) external onlyOwner {
        if (perf > MAX_PERF_FEE || mgmt > MAX_MGMT_FEE) revert InvalidParam();
        if (recipient == address(0)) revert InvalidParam();
        accrueFees();                      // settle at the old rate first
        performanceFee = perf;
        managementFee = mgmt;
        feeRecipient = recipient;
        emit FeesSet(perf, mgmt, recipient);
    }

    function setDepositCap(uint256 cap) external onlyCurator { depositCap = cap; emit DepositCapSet(cap); }

    function setWithdrawTimelock(uint64 secs) external onlyOwner {
        if (secs > MAX_TIMELOCK) revert InvalidParam();
        withdrawTimelock = secs;
        emit WithdrawTimelockSet(secs);
    }

    /// Set the strategy's external references and its operating bounds in one
    /// call: the price oracle, the staking contract, the swap slippage limit,
    /// the oracle-agreement tolerance, and the two health-factor levels.
    ///
    /// `minHF` is the health factor leverage must leave behind; below
    /// `unwindHF` anyone may unwind the position.
    function configureStrategy(
        address oracle_, address staking_, uint16 slippageBps,
        uint16 deviationBps, uint256 minHF, uint256 unwindHF
    ) external onlyOwner {
        if (slippageBps > MAX_SLIPPAGE) revert InvalidParam();
        if (deviationBps == 0 || deviationBps > MAX_DEVIATION) revert InvalidParam();
        if (minHF < HF_ONE || unwindHF < HF_ONE || unwindHF > minHF) revert InvalidParam();
        oracle = IPriceOracle(oracle_);
        staking = IStaking(staking_);
        maxSlippageBps = slippageBps;
        maxOracleDeviationBps = deviationBps;
        minHealthFactor = minHF;
        unwindHealthFactor = unwindHF;
        emit StrategyConfigured(oracle_, staking_, slippageBps, deviationBps, minHF, unwindHF);
    }

    /// Register a pool the vault may route through.
    ///
    /// `kind` 0 is a constant-product pair: `feeNum` is its fee numerator out
    /// of 1000, and the pool is probed to confirm it answers `getReserves`, so
    /// a pool of the wrong shape is rejected here rather than breaking a
    /// deposit later. `kind` 1 is a concentrated-liquidity pool reached through
    /// the router, and `feeNum` carries its fee tier in hundredths of a bip.
    function addVenue(address pair_, uint16 feeNum, uint8 kind) external onlyOwner {
        if (pair_ == address(0) || venues.length >= MAX_VENUES || kind > 1) revert InvalidParam();
        if (kind == 0 && (feeNum < 950 || feeNum > 1000)) revert InvalidParam();
        if (kind == 1 && (feeNum == 0 || swapRouter == address(0))) revert InvalidParam();
        for (uint256 i = 0; i < venues.length; i++) {
            if (venues[i].pair == pair_) revert InvalidParam();
        }
        if (kind == 0) VaultMath.reserves(pair_, address(whbar));   // must answer
        venues.push(VaultMath.Venue({pair: pair_, feeNum: feeNum, active: true, kind: kind}));
        emit VenueSet(venues.length - 1, pair_, true);
    }

    /// Set the router concentrated-liquidity venues trade through, and approve
    /// it for both tokens. Approvals are bounded, as HTS requires.
    function setSwapRouter(address router) external onlyOwner {
        swapRouter = router;
        if (router != address(0)) {
            IERC20(asset()).forceApprove(router, HTS_MAX);
            whbar.forceApprove(router, HTS_MAX);
        }
        emit SwapRouterSet(router);
    }

    /// Take a venue out of the routing set, or put it back.
    function setVenueActive(uint256 i, bool active) external onlyOwner {
        if (i >= venues.length) revert InvalidParam();
        venues[i].active = active;
        emit VenueSet(i, venues[i].pair, active);
    }

    /// Guardian or owner may pause, which halts deposits and withdrawals alike.
    /// Unwinding leverage stays available while paused; only the owner can lift it.
    function pause() external onlyGuardian { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover stray tokens. Can never touch the asset, collateral or debt,
    /// so no role can reach depositor funds.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (token == asset() || token == address(aToken) || token == address(debtToken)
            || token == address(whbar)) revert InvalidParam();
        if (to == address(0)) revert InvalidParam();
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert InvalidParam();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
