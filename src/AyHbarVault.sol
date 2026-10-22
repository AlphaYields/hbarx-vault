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
  consulted. Once debt exists it is valued only by the lending market's own
  oracle — the one that governs liquidation — and totalAssets() reverts if that
  oracle cannot answer. A market price that can be moved inside a block is never
  used to price shares.

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
    uint8   public  constant MAX_LOOPS      = 5;
    uint16  private constant MAX_SLIPPAGE   = 500;     // 5% hard ceiling

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
    uint16       public swapFeeNum = 997;
    uint16       public maxSlippageBps = 100;   // 1% operating limit, owner-settable
    bool         public associated;

    // ──────────────────────────────────────────────────────────────── events
    event Associated();
    event DepositedHBAR(address indexed caller, address indexed receiver, uint256 hbarIn, uint256 assets, uint256 shares);
    event WithdrawRequested(address indexed owner, uint256 shares, uint64 unlockAt);
    event WithdrawRequestCancelled(address indexed owner, uint256 shares);
    event FeesAccrued(uint256 performanceAssets, uint256 managementAssets, uint256 sharesMinted);
    event Supplied(uint256 amount);
    event Freed(uint256 amount);
    event Levered(uint8 loops, uint256 supplied, uint256 borrowed);
    event Deleveraged(uint8 loops, uint256 repaid);
    event RoleSet(bytes32 indexed role, address account);
    event FeesSet(uint16 performanceFee, uint16 managementFee, address feeRecipient);
    event DepositCapSet(uint256 cap);
    event MaxSlippageSet(uint16 bps);
    event WithdrawTimelockSet(uint64 seconds_);
    event OracleSet(address oracle);
    event StakingSet(address staking);

    error NotAuthorized();
    error CapExceeded();
    error NoMaturedRequest();
    error TimelockNotElapsed();
    error InvalidParam();

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
        if (associated) revert InvalidParam();
        IHRC719(asset()).associate();
        IHRC719(address(whbar)).associate();
        associated = true;
        IERC20(asset()).forceApprove(address(pool), HTS_MAX);
        whbar.forceApprove(address(pool), HTS_MAX);
        emit Associated();
    }

    function refreshApprovals() external {
        if (!associated) revert InvalidParam();
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
        uint256 pps = _pricePerShare(ta, ts);

        uint256 mgmtAssets;
        if (managementFee > 0) {
            uint256 dt = block.timestamp - lastFeeAccrual;
            mgmtAssets = ta.mulDiv(uint256(managementFee) * dt, BPS * 365 days, Math.Rounding.Floor);
        }

        uint256 perfAssets;
        if (performanceFee > 0 && pps > highWaterMark) {
            uint256 gain = (pps - highWaterMark).mulDiv(ts, 1e18, Math.Rounding.Floor);
            perfAssets = gain.mulDiv(performanceFee, BPS, Math.Rounding.Floor);
        }

        uint256 feeAssets = mgmtAssets + perfAssets;
        uint256 shares;
        if (feeAssets > 0 && feeAssets < ta && feeRecipient != address(0)) {
            // Shares whose value equals feeAssets *after* the dilution they cause.
            shares = feeAssets.mulDiv(ts + 10 ** _decimalsOffset(), ta - feeAssets + 1, Math.Rounding.Floor);
            if (shares > 0) _mint(feeRecipient, shares);
        }

        lastFeeAccrual = uint64(block.timestamp);
        uint256 newPps = _pricePerShare(totalAssets(), totalSupply());
        if (newPps > highWaterMark) highWaterMark = newPps;
        if (shares > 0 || feeAssets > 0) emit FeesAccrued(perfAssets, mgmtAssets, shares);
    }

    function _pricePerShare(uint256 ta, uint256 ts) internal pure returns (uint256) {
        return (ta + 1).mulDiv(1e18, ts + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// Current share price, in assets per whole share. Starts at 1.0 and rises.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    // ════════════════════════════════════════════════════════════ accounting
    /// OpenZeppelin defaults this to 0, which leaves the first-depositor
    /// donation attack viable. A non-zero offset makes the attack uneconomic.
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    function totalAssets() public view override returns (uint256) {
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + aToken.balanceOf(address(this));
        uint256 debt = debtToken.balanceOf(address(this));
        if (debt == 0) return gross;

        if (address(oracle) == address(0)) revert InvalidParam();
        uint256 pW = oracle.getAssetPrice(address(whbar));
        uint256 pA = oracle.getAssetPrice(asset());
        if (pW == 0 || pA == 0) revert InvalidParam();

        uint256 debtInAsset = debt.mulDiv(pW, pA, Math.Rounding.Ceil);
        return gross > debtInAsset ? gross - debtInAsset : 0;
    }

    /// Assets the vault could hand over right now: idle plus recoverable collateral.
    function liquidAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + aToken.balanceOf(address(this));
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

        uint256 before = IERC20(asset()).balanceOf(address(this));
        _hbarToAsset(msg.value);
        uint256 assets = IERC20(asset()).balanceOf(address(this)) - before;
        if (assets < minAssetsOut || assets == 0) revert InvalidParam();
        if (assets > maxDeposit(receiver)) revert CapExceeded();

        // Price against the state before these assets landed.
        uint256 ts = totalSupply();
        if (ts == 0) {
            shares = assets * 10 ** _decimalsOffset();
        } else {
            uint256 taAfter = totalAssets();
            uint256 taBefore = taAfter > assets ? taAfter - assets : 0;
            shares = assets.mulDiv(ts + 10 ** _decimalsOffset(), taBefore + 1, Math.Rounding.Floor);
        }
        if (shares == 0) revert InvalidParam();
        _mint(receiver, shares);
        // The standard event first, so ERC-4626 indexers see every deposit; the
        // second carries the HBAR detail the standard one has no room for.
        emit Deposit(msg.sender, receiver, assets, shares);
        emit DepositedHBAR(msg.sender, receiver, msg.value, assets, shares);
    }

    function _hbarToAsset(uint256 hbarAmount) internal {
        if (address(staking) != address(0)) {
            staking.stake{value: hbarAmount}();
            return;
        }
        uint256 wBefore = whbar.balanceOf(address(this));
        whbarWrapper.deposit{value: hbarAmount}();
        uint256 wGot = whbar.balanceOf(address(this)) - wBefore;
        if (wGot == 0) revert InvalidParam();
        _swap(address(whbar), wGot, 0);   // bounded by minAssetsOut upstream
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

    function _freeForWithdrawal(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        uint256 need = assets - idle;
        uint256 coll = aToken.balanceOf(address(this));
        if (need > coll) need = coll;
        if (need > 0) {
            pool.withdraw(asset(), need, address(this));
            emit Freed(need);
        }
    }

    // ══════════════════════════════════════════════════════════════ strategy
    function supplyToPool(uint256 amount) external onlyCurator nonReentrant {
        if (amount == 0) amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) revert InvalidParam();
        pool.deposit(asset(), amount, address(this), 0);
        emit Supplied(amount);
    }

    function withdrawFromPool(uint256 amount) external onlyCurator nonReentrant {
        if (amount == 0) amount = aToken.balanceOf(address(this));
        if (amount == 0) revert InvalidParam();
        pool.withdraw(asset(), amount, address(this));
        emit Freed(amount);
    }

    function enableCollateral() external onlyCurator nonReentrant {
        pool.setUserUseReserveAsCollateral(asset(), true);
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

            uint256 expected = quoteWhbarToAsset(got);
            _swap(address(whbar), got, expected.mulDiv(BPS - slippageBps, BPS, Math.Rounding.Floor));
        }
        emit Levered(loops, supplied, borrowed);
    }

    /// Unwind leverage. Reads balances only, so it keeps working even when
    /// totalAssets() cannot price itself. Guardian may call this in an emergency.
    function deleverage(uint8 loops, uint256 withdrawPerLoop, uint16 slippageBps)
        external onlyGuardian nonReentrant
    {
        if (loops == 0 || loops > MAX_LOOPS) revert InvalidParam();
        if (slippageBps > maxSlippageBps) revert InvalidParam();
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
            uint256 got = _swap(asset(), have, expected.mulDiv(BPS - slippageBps, BPS, Math.Rounding.Floor));

            uint256 amt = got > debt ? debt : got;
            pool.repay(address(whbar), amt, VARIABLE_RATE, address(this));
            repaid += amt;
        }
        emit Deleveraged(loops, repaid);
    }

    // ═════════════════════════════════════════════════════════════════ swaps
    function _reserves() internal view returns (uint256 rW, uint256 rA) {
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        return pair.token0() == address(whbar) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _out(uint256 amtIn, uint256 rIn, uint256 rOut) internal view returns (uint256) {
        if (rIn == 0 || rOut == 0) revert InvalidParam();
        uint256 inFee = amtIn * swapFeeNum;
        return (inFee * rOut) / (rIn * 1000 + inFee);
    }

    function quoteWhbarToAsset(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, w, x); }
    function quoteAssetToWhbar(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, x, w); }

    function _swap(address tokenIn, uint256 amtIn, uint256 minOut) internal returns (uint256 out) {
        bool inIsWhbar = tokenIn == address(whbar);
        (uint256 rW, uint256 rA) = _reserves();
        uint256 expected = inIsWhbar ? _out(amtIn, rW, rA) : _out(amtIn, rA, rW);
        if (expected < minOut || expected == 0) revert InvalidParam();

        IERC20(tokenIn).safeTransfer(address(pair), amtIn);
        bool t0IsWhbar = pair.token0() == address(whbar);
        (uint256 a0, uint256 a1) = inIsWhbar
            ? (t0IsWhbar ? (uint256(0), expected) : (expected, uint256(0)))
            : (t0IsWhbar ? (expected, uint256(0)) : (uint256(0), expected));

        IERC20 outTok = inIsWhbar ? IERC20(asset()) : whbar;
        uint256 before = outTok.balanceOf(address(this));
        pair.swap(a0, a1, address(this), "");
        out = outTok.balanceOf(address(this)) - before;
        if (out < minOut) revert InvalidParam();
    }

    // ═════════════════════════════════════════════════════════════════ views
    function position() external view returns (uint256 collateral, uint256 debt, uint256 idle, uint256 nav) {
        collateral = aToken.balanceOf(address(this));
        debt = debtToken.balanceOf(address(this));
        idle = IERC20(asset()).balanceOf(address(this));
        nav = debt == 0 ? idle + collateral : totalAssets();
    }

    function healthFactor() external view returns (uint256 hf) {
        (, , , , , hf) = pool.getUserAccountData(address(this));
    }

    // ═════════════════════════════════════════════════════════════════ admin
    function setGuardian(address v) external onlyOwner { guardian = v; emit RoleSet("guardian", v); }
    function setCurator(address v) external onlyOwner { curator = v; emit RoleSet("curator", v); }

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

    function setOracle(address v) external onlyOwner { oracle = IPriceOracle(v); emit OracleSet(v); }
    function setStaking(address v) external onlyOwner { staking = IStaking(v); emit StakingSet(v); }
    function setMaxSlippageBps(uint16 v) external onlyOwner {
        if (v > MAX_SLIPPAGE) revert InvalidParam();
        maxSlippageBps = v;
        emit MaxSlippageSet(v);
    }

    function setSwapFeeNum(uint16 v) external onlyOwner {
        if (v < 950 || v > 1000) revert InvalidParam();
        swapFeeNum = v;
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
