// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPairView {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface ILendingView {
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateral, uint256 totalDebt, uint256 availableBorrows,
        uint256 liquidationThreshold, uint256 ltv, uint256 healthFactor);
}

/**
 * Pricing, routing and position arithmetic for AyHbarVault.
 *
 * Deployed separately and linked, which keeps the vault itself inside the
 * 24 KB contract-code limit. Every function here is `view` or `pure` and none
 * moves a token: nothing in this library depends on the caller's context, so
 * running it through a library call changes no behaviour.
 */
library VaultMath {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;

    /// A pool the vault may route through.
    ///
    /// `kind` 0 is a constant-product pair, quoted and swapped directly.
    /// `kind` 1 is a concentrated-liquidity pool, swapped through a router.
    /// A concentrated pool cannot be quoted from reserves, so `quote` reports
    /// zero for one — which keeps it out of automatic routing and, just as
    /// importantly, means registering one can never break a deposit.
    struct Venue { address pair; uint16 feeNum; bool active; uint8 kind; }

    uint8 internal constant KIND_CONSTANT_PRODUCT = 0;
    uint8 internal constant KIND_CONCENTRATED     = 1;

    /// Constant-product output after the venue's fee.
    function amountOut(uint256 amtIn, uint256 rIn, uint256 rOut, uint16 feeNum)
        public pure returns (uint256)
    {
        if (rIn == 0 || rOut == 0 || amtIn == 0) return 0;
        uint256 inFee = amtIn * feeNum;
        return (inFee * rOut) / (rIn * 1000 + inFee);
    }

    /// Reserves of a pair, ordered (WHBAR, asset) regardless of token order.
    function reserves(address pair, address whbar) public view returns (uint256 rW, uint256 rA) {
        (uint112 r0, uint112 r1, ) = IPairView(pair).getReserves();
        return IPairView(pair).token0() == whbar ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// What one venue would pay for `amtIn`, after its fee and price impact.
    function quote(Venue memory v, address whbar, bool inIsWhbar, uint256 amtIn)
        public view returns (uint256)
    {
        if (!v.active || v.pair == address(0) || v.kind != KIND_CONSTANT_PRODUCT) return 0;
        (uint256 rW, uint256 rA) = reserves(v.pair, whbar);
        return inIsWhbar ? amountOut(amtIn, rW, rA, v.feeNum) : amountOut(amtIn, rA, rW, v.feeNum);
    }

    /// The venue paying most for a given input, and what it pays.
    function best(Venue[] memory vs, address whbar, bool inIsWhbar, uint256 amtIn)
        public view returns (uint256 index, uint256 out)
    {
        for (uint256 i = 0; i < vs.length; i++) {
            uint256 q = quote(vs[i], whbar, inIsWhbar, amtIn);
            if (q > out) { out = q; index = i; }
        }
    }

    /// Read a uint from a view call, reporting failure instead of bubbling it.
    /// Used where an unavailable source should be skipped rather than fatal.
    function tryUint(address target, bytes memory data) public view returns (bool, uint256) {
        if (target == address(0)) return (false, 0);
        (bool ok, bytes memory out) = target.staticcall(data);
        if (!ok || out.length < 32) return (false, 0);
        return (true, abi.decode(out, (uint256)));
    }

    /// Collateral withdrawable while keeping the position at `minHealthFactor`.
    ///
    /// The lending market releases collateral only while the position stays
    /// healthy afterwards, so the freeable amount is bounded by the debt and
    /// the liquidation threshold — never the whole collateral balance.
    function freeableCollateral(address pool, address self, uint256 coll, uint256 minHealthFactor)
        public view returns (uint256)
    {
        (uint256 totalCollateral, uint256 totalDebt, , uint256 liqThreshold, , ) =
            ILendingView(pool).getUserAccountData(self);
        if (totalDebt == 0) return coll;
        if (totalCollateral == 0 || liqThreshold == 0) return 0;

        uint256 keepBase = totalDebt.mulDiv(minHealthFactor, 1e18, Math.Rounding.Ceil)
                                    .mulDiv(BPS, liqThreshold, Math.Rounding.Ceil);
        if (keepBase >= totalCollateral) return 0;
        return (totalCollateral - keepBase).mulDiv(coll, totalCollateral, Math.Rounding.Floor);
    }

    /// Fees owed for a period, and the shares that pay them.
    ///
    /// The performance fee applies only to the gain above the high-water mark,
    /// so ground already charged for is never charged again. The management fee
    /// accrues pro-rata over time. Both are paid by minting shares, and the
    /// share count is the amount worth `feeAssets` *after* the dilution it
    /// causes — which is why the denominator carries the fee.
    function feeAccrual(
        uint256 totalAssets_, uint256 totalSupply_, uint256 highWaterMark,
        uint256 pricePerShare_, uint16 perfFeeBps, uint16 mgmtFeeBps,
        uint256 elapsed, uint256 offsetUnits
    ) public pure returns (uint256 perfAssets, uint256 mgmtAssets, uint256 shares) {
        if (mgmtFeeBps > 0 && elapsed > 0) {
            mgmtAssets = totalAssets_.mulDiv(uint256(mgmtFeeBps) * elapsed, BPS * 365 days, Math.Rounding.Floor);
        }
        if (perfFeeBps > 0 && pricePerShare_ > highWaterMark) {
            uint256 gain = (pricePerShare_ - highWaterMark).mulDiv(totalSupply_, 1e18, Math.Rounding.Floor);
            perfAssets = gain.mulDiv(perfFeeBps, BPS, Math.Rounding.Floor);
        }
        uint256 feeAssets = perfAssets + mgmtAssets;
        if (feeAssets > 0 && feeAssets < totalAssets_) {
            shares = feeAssets.mulDiv(totalSupply_ + offsetUnits,
                                      totalAssets_ - feeAssets + 1, Math.Rounding.Floor);
        }
    }

    /// Price per share, scaled by 1e18. The virtual offset in the denominator
    /// is the first-depositor protection: it makes a donation attack uneconomic.
    function pricePerShare(uint256 totalAssets_, uint256 totalSupply_, uint256 offsetUnits)
        public pure returns (uint256)
    {
        return (totalAssets_ + 1).mulDiv(1e18, totalSupply_ + offsetUnits, Math.Rounding.Floor);
    }

    /// Shares for assets that have already landed in the vault, priced against
    /// the state before they arrived.
    function sharesForArrivedAssets(
        uint256 assets, uint256 totalSupply_, uint256 totalAssetsAfter, uint256 offsetUnits
    ) public pure returns (uint256) {
        if (totalSupply_ == 0) return assets * offsetUnits;
        uint256 before = totalAssetsAfter > assets ? totalAssetsAfter - assets : 0;
        return assets.mulDiv(totalSupply_ + offsetUnits, before + 1, Math.Rounding.Floor);
    }

    /// WHBAR per whole asset unit, 1e8-scaled, from the staking rate anchored
    /// against the lending oracle. Returns 0 when no source answers, and
    /// signals disagreement separately so the caller can refuse to price.
    function priceInWhbar(
        address staking, address oracle, address asset_, address whbar, uint16 maxDeviationBps
    ) public view returns (uint256 price, bool available, bool agrees) {
        (bool okS, uint256 fromStaking) = tryUint(staking, abi.encodeWithSignature("getExchangeRate()"));
        uint256 fromOracle;
        (bool okA, uint256 pA) = tryUint(oracle, abi.encodeWithSignature("getAssetPrice(address)", asset_));
        (bool okW, uint256 pW) = tryUint(oracle, abi.encodeWithSignature("getAssetPrice(address)", whbar));
        if (okA && okW && pA > 0 && pW > 0) fromOracle = pA.mulDiv(1e8, pW, Math.Rounding.Floor);
        return anchoredPrice(okS ? fromStaking : 0, fromOracle, maxDeviationBps);
    }

    /// Reconcile the staking rate against the lending oracle.
    ///
    /// The staking protocol's redemption rate is the anchor: it is set by the
    /// staking contract, moves only as rewards accrue, and cannot be pushed by
    /// trading. The oracle is a second opinion, and the two must agree within
    /// `maxDeviationBps` — so neither source can move the share price alone.
    /// Returns WHBAR per whole asset unit, 1e8-scaled.
    function anchoredPrice(uint256 fromStaking, uint256 fromOracle, uint16 maxDeviationBps)
        public pure returns (uint256 price, bool available, bool agrees)
    {
        if (fromStaking == 0 && fromOracle == 0) return (0, false, false);
        if (fromStaking == 0) return (fromOracle, true, true);
        if (fromOracle == 0) return (fromStaking, true, true);
        uint256 diff = fromStaking > fromOracle ? fromStaking - fromOracle : fromOracle - fromStaking;
        agrees = diff.mulDiv(BPS, fromStaking, Math.Rounding.Ceil) <= maxDeviationBps;
        return (fromStaking, true, agrees);
    }
}
