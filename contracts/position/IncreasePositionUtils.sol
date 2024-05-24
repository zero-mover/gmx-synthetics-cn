// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../utils/Precision.sol";

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "../oracle/Oracle.sol";
import "../pricing/PositionPricingUtils.sol";

import "./Position.sol";
import "./PositionStoreUtils.sol";
import "./PositionUtils.sol";
import "./PositionEventUtils.sol";
import "../order/BaseOrderUtils.sol";

// @title IncreasePositionUtils
// @dev Library for functions to help with increasing a position
library IncreasePositionUtils {
    using SafeCast for uint256;
    using SafeCast for int256;

    using Position for Position.Props;
    using Order for Order.Props;
    using Price for Price.Props;

    // @dev IncreasePositionCache struct used in increasePosition to
    // avoid stack too deep errors
    // @param collateralDeltaAmount the change in collateral amount
    // @param executionPrice the execution price
    // @param collateralTokenPrice the price of the collateral token
    // @param priceImpactUsd the price impact in USD
    // @param priceImpactAmount the price impact of the position increase in tokens
    // @param sizeDeltaInTokens the change in position size in tokens
    // @param nextPositionSizeInUsd the new position size in USD
    // @param nextPositionBorrowingFactor the new position borrowing factor
    struct IncreasePositionCache {
        int256 collateralDeltaAmount;
        uint256 executionPrice;
        Price.Props collateralTokenPrice;
        int256 priceImpactUsd;
        int256 priceImpactAmount;
        uint256 sizeDeltaInTokens;
        uint256 nextPositionSizeInUsd;
        uint256 nextPositionBorrowingFactor;
    }

    // @dev increase a position
    // The increasePosition function is used to increase the size of a position
    // in a market. This involves updating the position's collateral amount,
    // calculating the price impact of the size increase, and updating the position's
    // size and borrowing factor. This function also applies fees to the position
    // and updates the market's liquidity pool based on the new position size.
    // @param params PositionUtils.UpdatePositionParams
    function increasePosition(
        PositionUtils.UpdatePositionParams memory params,
        uint256 collateralIncrementAmount
    ) external {
        // get the market prices for the given position
        //获取池子各种代币的价格(最多三种代币)
        MarketUtils.MarketPrices memory prices = MarketUtils.getMarketPrices(params.contracts.oracle, params.market);
        //根据时间分配impact pool Amount
        MarketUtils.distributePositionImpactPool(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market.marketToken
        );
        //借用费和资金费更新
        PositionUtils.updateFundingAndBorrowingState(params, prices);

        // create a new cache for holding intermediate results
        IncreasePositionCache memory cache;
        //获取存入保证金的价格
        cache.collateralTokenPrice = MarketUtils.getCachedTokenPrice(
            params.position.collateralToken(),
            params.market,
            prices
        );
        if (params.position.sizeInUsd() == 0) {
            //设置position fundingfee
            params.position.setFundingFeeAmountPerSize(
                MarketUtils.getFundingFeeAmountPerSize(
                    params.contracts.dataStore,
                    params.market.marketToken,
                    params.position.collateralToken(),
                    params.position.isLong()
                )
            );

            params.position.setLongTokenClaimableFundingAmountPerSize(
                MarketUtils.getClaimableFundingAmountPerSize(
                    params.contracts.dataStore,
                    params.market.marketToken,
                    params.market.longToken,
                    params.position.isLong()
                )
            );

            params.position.setShortTokenClaimableFundingAmountPerSize(
                MarketUtils.getClaimableFundingAmountPerSize(
                    params.contracts.dataStore,
                    params.market.marketToken,
                    params.market.shortToken,
                    params.position.isLong()
                )
            );
        }

        (cache.priceImpactUsd, cache.priceImpactAmount, cache.sizeDeltaInTokens, cache.executionPrice) = PositionUtils
            .getExecutionPriceForIncrease(params, prices.indexTokenPrice);

        // process the collateral for the given position and order
        PositionPricingUtils.PositionFees memory fees;
        //更新仓位
        (cache.collateralDeltaAmount, fees) = processCollateral(
            params,
            cache.collateralTokenPrice,
            collateralIncrementAmount.toInt256(),
            cache.priceImpactUsd
        );

        // check if there is sufficient collateral for the position
        if (
            cache.collateralDeltaAmount < 0 &&
            params.position.collateralAmount() < SafeCast.toUint256(-cache.collateralDeltaAmount)
        ) {
            revert Errors.InsufficientCollateralAmount(params.position.collateralAmount(), cache.collateralDeltaAmount);
        }
        //
        params.position.setCollateralAmount(
            Calc.sumReturnUint256(params.position.collateralAmount(), cache.collateralDeltaAmount)
        );

        // if there is a positive impact, the impact pool amount should be reduced
        // if there is a negative impact, the impact pool amount should be increased
        //如果为正 则池子减少影响 因为这笔交易改善了池子的多空比倾斜
        MarketUtils.applyDeltaToPositionImpactPool(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market.marketToken,
            -cache.priceImpactAmount
        );
        //nextPositionSizeInUsd 用户开仓所有的金额
        cache.nextPositionSizeInUsd = params.position.sizeInUsd() + params.order.sizeDeltaUsd();
        //
        cache.nextPositionBorrowingFactor = MarketUtils.getCumulativeBorrowingFactor(
            params.contracts.dataStore,
            params.market.marketToken,
            params.position.isLong()
        );
        //更新全局 borrow
        PositionUtils.updateTotalBorrowing(params, cache.nextPositionSizeInUsd, cache.nextPositionBorrowingFactor);

        PositionUtils.incrementClaimableFundingAmount(params, fees);

        params.position.setSizeInUsd(cache.nextPositionSizeInUsd);
        params.position.setSizeInTokens(params.position.sizeInTokens() + cache.sizeDeltaInTokens);

        params.position.setFundingFeeAmountPerSize(fees.funding.latestFundingFeeAmountPerSize);
        params.position.setLongTokenClaimableFundingAmountPerSize(
            fees.funding.latestLongTokenClaimableFundingAmountPerSize
        );
        params.position.setShortTokenClaimableFundingAmountPerSize(
            fees.funding.latestShortTokenClaimableFundingAmountPerSize
        );

        params.position.setBorrowingFactor(cache.nextPositionBorrowingFactor);
        params.position.setIncreasedAtBlock(Chain.currentBlockNumber());

        PositionStoreUtils.set(params.contracts.dataStore, params.positionKey, params.position);

        PositionUtils.updateOpenInterest(
            params,
            params.order.sizeDeltaUsd().toInt256(),
            cache.sizeDeltaInTokens.toInt256()
        );

        if (params.order.sizeDeltaUsd() > 0) {
            // reserves are only validated if the sizeDeltaUsd is more than zero
            // this helps to ensure that deposits of collateral into positions
            // should still succeed even if pool tokens are fully reserved
            //验证开仓不能超过最大Reserve
            MarketUtils.validateReserve(params.contracts.dataStore, params.market, prices, params.order.isLong());
            //验证开仓不能超过OpenInterestReserve
            MarketUtils.validateOpenInterestReserve(
                params.contracts.dataStore,
                params.market,
                prices,
                params.order.isLong()
            );
            //
            PositionUtils.WillPositionCollateralBeSufficientValues memory positionValues = PositionUtils
                .WillPositionCollateralBeSufficientValues(
                    params.position.sizeInUsd(), // positionSizeInUsd
                    params.position.collateralAmount(), // positionCollateralAmount
                    0, // realizedPnlUsd
                    0 // openInterestDelta
                );
            //校验保证金
            (bool willBeSufficient, int256 remainingCollateralUsd) = PositionUtils.willPositionCollateralBeSufficient(
                params.contracts.dataStore,
                params.market,
                prices,
                params.position.collateralToken(),
                params.position.isLong(),
                positionValues
            );

            if (!willBeSufficient) {
                revert Errors.InsufficientCollateralUsd(remainingCollateralUsd);
            }
        }

        PositionUtils.handleReferral(params, fees);

        // validatePosition should be called after open interest and all other market variables
        // have been updated
        //校验仓位
        PositionUtils.validatePosition(
            params.contracts.dataStore,
            params.contracts.referralStorage,
            params.position,
            params.market,
            prices,
            true, // shouldValidateMinPositionSize
            true // shouldValidateMinCollateralUsd
        );

        PositionEventUtils.emitPositionFeesCollected(
            params.contracts.eventEmitter,
            params.orderKey,
            params.positionKey,
            params.market.marketToken,
            params.position.collateralToken(),
            params.order.sizeDeltaUsd(),
            true,
            fees
        );

        PositionEventUtils.PositionIncreaseParams memory eventParams;
        eventParams.eventEmitter = params.contracts.eventEmitter;
        eventParams.orderKey = params.orderKey;
        eventParams.positionKey = params.positionKey;
        eventParams.position = params.position;
        eventParams.indexTokenPrice = prices.indexTokenPrice;
        eventParams.executionPrice = cache.executionPrice;
        eventParams.collateralTokenPrice = cache.collateralTokenPrice;
        eventParams.sizeDeltaUsd = params.order.sizeDeltaUsd();
        eventParams.sizeDeltaInTokens = cache.sizeDeltaInTokens;
        eventParams.collateralDeltaAmount = cache.collateralDeltaAmount;
        eventParams.priceImpactUsd = cache.priceImpactUsd;
        eventParams.priceImpactAmount = cache.priceImpactAmount;
        eventParams.orderType = params.order.orderType();

        PositionEventUtils.emitPositionIncrease(eventParams);
    }

    // @dev handle the collateral changes of the position
    // @param params PositionUtils.UpdatePositionParams
    // @param prices the prices of the tokens in the market
    // @param position the position to process collateral for
    // @param collateralDeltaAmount the change in the position's collateral
    function processCollateral(
        PositionUtils.UpdatePositionParams memory params,
        Price.Props memory collateralTokenPrice,
        int256 collateralDeltaAmount,
        int256 priceImpactUsd
    ) internal returns (int256, PositionPricingUtils.PositionFees memory) {
        //构造参数
        PositionPricingUtils.GetPositionFeesParams memory getPositionFeesParams = PositionPricingUtils
            .GetPositionFeesParams(
                params.contracts.dataStore, // dataStore
                params.contracts.referralStorage, // referralStorage
                params.position, // position
                collateralTokenPrice, // collateralTokenPrice
                priceImpactUsd > 0, // forPositiveImpact
                params.market.longToken, // longToken
                params.market.shortToken, // shortToken
                params.order.sizeDeltaUsd(), // sizeDeltaUsd
                params.order.uiFeeReceiver() // uiFeeReceiver
            );
        //获取所有费
        PositionPricingUtils.PositionFees memory fees = PositionPricingUtils.getPositionFees(getPositionFeesParams);
        //更新fee的全局变量
        FeeUtils.incrementClaimableFeeAmount(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market.marketToken,
            params.position.collateralToken(),
            fees.feeReceiverAmount,
            Keys.POSITION_FEE_TYPE
        );
        //更新UIfee的全局变量
        FeeUtils.incrementClaimableUiFeeAmount(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.order.uiFeeReceiver(),
            params.market.marketToken,
            params.position.collateralToken(),
            fees.ui.uiFeeAmount,
            Keys.UI_POSITION_FEE_TYPE
        );
        //计算一下剩余保证金
        collateralDeltaAmount -= fees.totalCostAmount.toInt256();
        //更新全局保证金
        MarketUtils.applyDeltaToCollateralSum(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.order.market(),
            params.position.collateralToken(),
            params.order.isLong(),
            collateralDeltaAmount
        );
        //更新池子资金
        MarketUtils.applyDeltaToPoolAmount(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market,
            params.position.collateralToken(),
            fees.feeAmountForPool.toInt256()
        );

        return (collateralDeltaAmount, fees);
    }
}
