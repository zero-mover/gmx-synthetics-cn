// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../data/Keys.sol";
import "../utils/Precision.sol";

import "../deposit/Deposit.sol";
import "../withdrawal/Withdrawal.sol";
import "../order/Order.sol";
import "../order/BaseOrderUtils.sol";

import "../bank/StrictBank.sol";

// @title GasUtils
// @dev Library for execution fee estimation and payments
library GasUtils {
    using Deposit for Deposit.Props;
    using Withdrawal for Withdrawal.Props;
    using Order for Order.Props;

    using EventUtils for EventUtils.AddressItems;
    using EventUtils for EventUtils.UintItems;
    using EventUtils for EventUtils.IntItems;
    using EventUtils for EventUtils.BoolItems;
    using EventUtils for EventUtils.Bytes32Items;
    using EventUtils for EventUtils.BytesItems;
    using EventUtils for EventUtils.StringItems;

    // @param keeper address of the keeper
    // @param amount the amount of execution fee received
    event KeeperExecutionFee(address keeper, uint256 amount);
    // @param user address of the user
    // @param amount the amount of execution fee refunded
    event UserRefundFee(address user, uint256 amount);

    function getMinHandleExecutionErrorGas(DataStore dataStore) internal view returns (uint256) {
        return dataStore.getUint(Keys.MIN_HANDLE_EXECUTION_ERROR_GAS);
    }

    function getMinHandleExecutionErrorGasToForward(DataStore dataStore) internal view returns (uint256) {
        return dataStore.getUint(Keys.MIN_HANDLE_EXECUTION_ERROR_GAS_TO_FORWARD);
    }

    function getMinAdditionalGasForExecution(DataStore dataStore) internal view returns (uint256) {
        return dataStore.getUint(Keys.MIN_ADDITIONAL_GAS_FOR_EXECUTION);
    }

    function getExecutionGas(DataStore dataStore, uint256 startingGas) internal view returns (uint256) {
        uint256 minHandleExecutionErrorGasToForward = GasUtils.getMinHandleExecutionErrorGasToForward(dataStore);
        if (startingGas < minHandleExecutionErrorGasToForward) {
            revert Errors.InsufficientExecutionGasForErrorHandling(startingGas, minHandleExecutionErrorGasToForward);
        }

        return startingGas - minHandleExecutionErrorGasToForward;
    }

    function validateExecutionGas(DataStore dataStore, uint256 startingGas, uint256 estimatedGasLimit) internal view {
        uint256 minAdditionalGasForExecution = getMinAdditionalGasForExecution(dataStore);
        if (startingGas < estimatedGasLimit + minAdditionalGasForExecution) {
            revert Errors.InsufficientExecutionGas(startingGas, estimatedGasLimit, minAdditionalGasForExecution);
        }
    }

    // a minimum amount of gas is required to be left for cancellation
    // to prevent potential blocking of cancellations by malicious contracts using e.g. large revert reasons
    //
    // during the estimateGas call by keepers, an insufficient amount of gas may be estimated
    // the amount estimated may be insufficient for execution but sufficient for cancellaton
    // this could lead to invalid cancellations due to insufficient gas used by keepers
    //
    // to help prevent this, out of gas errors are attempted to be caught and reverted for estimateGas calls
    //
    // a malicious user could cause the estimateGas call of a keeper to fail, in which case the keeper could
    // still attempt to execute the transaction with a reasonable gas limit
    function validateExecutionErrorGas(DataStore dataStore, bytes memory reasonBytes) internal view {
        // skip the validation if the execution did not fail due to an out of gas error
        // also skip the validation if this is not invoked in an estimateGas call (tx.origin != address(0))
        if (reasonBytes.length != 0 || tx.origin != address(0)) {
            return;
        }

        uint256 gas = gasleft();
        uint256 minHandleExecutionErrorGas = getMinHandleExecutionErrorGas(dataStore);

        if (gas < minHandleExecutionErrorGas) {
            revert Errors.InsufficientHandleExecutionErrorGas(gas, minHandleExecutionErrorGas);
        }
    }

    // @dev pay the keeper the execution fee and refund any excess amount
    //
    // @param dataStore DataStore
    // @param bank the StrictBank contract holding the execution fee
    // @param executionFee the executionFee amount
    // @param startingGas the starting gas
    // @param keeper the keeper to pay
    // @param refundReceiver the account that should receive any excess gas refunds
    // 付keeper地址执行费并退还多余资金
    function payExecutionFee(
        DataStore dataStore,
        EventEmitter eventEmitter,
        StrictBank bank,
        uint256 executionFee,
        uint256 startingGas,
        address keeper,
        address refundReceiver
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        //默认情况下，在进行外部调用时，会将 63/64 的 gas 转发给被调用的合约或函数，剩下的 1/64 会留给当前合约
        //这里预留1/63 
        startingGas -= gasleft() / 63;
        //剩余的gas 要收的执行费
        uint256 gasUsed = startingGas - gasleft();

        // each external call forwards 63/64 of the remaining gas
        uint256 executionFeeForKeeper = adjustGasUsage(dataStore, gasUsed) * tx.gasprice;

        if (executionFeeForKeeper > executionFee) {
            executionFeeForKeeper = executionFee;
        }

        bank.transferOutNativeToken(keeper, executionFeeForKeeper);

        emitKeeperExecutionFee(eventEmitter, keeper, executionFeeForKeeper);

        uint256 refundFeeAmount = executionFee - executionFeeForKeeper;
        if (refundFeeAmount == 0) {
            return;
        }

        bank.transferOutNativeToken(refundReceiver, refundFeeAmount);

        emitExecutionFeeRefund(eventEmitter, refundReceiver, refundFeeAmount);
    }

    // @dev validate that the provided executionFee is sufficient based on the estimatedGasLimit
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    // @param executionFee the execution fee provided
    function validateExecutionFee(DataStore dataStore, uint256 estimatedGasLimit, uint256 executionFee) internal view {
        uint256 gasLimit = adjustGasLimitForEstimate(dataStore, estimatedGasLimit);
        uint256 minExecutionFee = gasLimit * tx.gasprice;
        if (executionFee < minExecutionFee) {
            revert Errors.InsufficientExecutionFee(minExecutionFee, executionFee);
        }
    }

    // @dev adjust the gas usage to pay a small amount to keepers
    // @param dataStore DataStore
    // @param gasUsed the amount of gas used
    function adjustGasUsage(DataStore dataStore, uint256 gasUsed) internal view returns (uint256) {
        // gas measurements are done after the call to withOraclePrices
        // withOraclePrices may consume a significant amount of gas
        // the baseGasLimit used to calculate the execution cost
        // should be adjusted to account for this
        // additionally, a transaction could fail midway through an execution transaction
        // before being cancelled, the possibility of this additional gas cost should
        // be considered when setting the baseGasLimit
        uint256 baseGasLimit = dataStore.getUint(Keys.EXECUTION_GAS_FEE_BASE_AMOUNT);
        // the gas cost is estimated based on the gasprice of the request txn
        // the actual cost may be higher if the gasprice is higher in the execution txn
        // the multiplierFactor should be adjusted to account for this
        uint256 multiplierFactor = dataStore.getUint(Keys.EXECUTION_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = baseGasLimit + Precision.applyFactor(gasUsed, multiplierFactor);
        return gasLimit;
    }

    // @dev adjust the estimated gas limit to help ensure the execution fee is sufficient during
    // the actual execution
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    function adjustGasLimitForEstimate(DataStore dataStore, uint256 estimatedGasLimit) internal view returns (uint256) {
        uint256 baseGasLimit = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = baseGasLimit + Precision.applyFactor(estimatedGasLimit, multiplierFactor);
        return gasLimit;
    }

    // @dev the estimated gas limit for deposits
    // @param dataStore DataStore
    // @param deposit the deposit to estimate the gas limit for
    function estimateExecuteDepositGasLimit(
        DataStore dataStore,
        Deposit.Props memory deposit
    ) internal view returns (uint256) {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        uint256 swapCount = deposit.longTokenSwapPath().length + deposit.shortTokenSwapPath().length;
        uint256 gasForSwaps = swapCount * gasPerSwap;

        if (deposit.initialLongTokenAmount() == 0 || deposit.initialShortTokenAmount() == 0) {
            return dataStore.getUint(Keys.depositGasLimitKey(true)) + deposit.callbackGasLimit() + gasForSwaps;
        }

        return dataStore.getUint(Keys.depositGasLimitKey(false)) + deposit.callbackGasLimit() + gasForSwaps;
    }

    // @dev the estimated gas limit for withdrawals
    // @param dataStore DataStore
    // @param withdrawal the withdrawal to estimate the gas limit for
    function estimateExecuteWithdrawalGasLimit(
        DataStore dataStore,
        Withdrawal.Props memory withdrawal
    ) internal view returns (uint256) {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        uint256 swapCount = withdrawal.longTokenSwapPath().length + withdrawal.shortTokenSwapPath().length;
        uint256 gasForSwaps = swapCount * gasPerSwap;

        return dataStore.getUint(Keys.withdrawalGasLimitKey()) + withdrawal.callbackGasLimit() + gasForSwaps;
    }

    // @dev the estimated gas limit for orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteOrderGasLimit(
        DataStore dataStore,
        Order.Props memory order
    ) internal view returns (uint256) {
        if (BaseOrderUtils.isIncreaseOrder(order.orderType())) {
            return estimateExecuteIncreaseOrderGasLimit(dataStore, order);
        }

        if (BaseOrderUtils.isDecreaseOrder(order.orderType())) {
            return estimateExecuteDecreaseOrderGasLimit(dataStore, order);
        }

        if (BaseOrderUtils.isSwapOrder(order.orderType())) {
            return estimateExecuteSwapOrderGasLimit(dataStore, order);
        }

        revert Errors.UnsupportedOrderType();
    }

    // @dev the estimated gas limit for increase orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteIncreaseOrderGasLimit(
        DataStore dataStore,
        Order.Props memory order
    ) internal view returns (uint256) {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        return
            dataStore.getUint(Keys.increaseOrderGasLimitKey()) +
            gasPerSwap *
            order.swapPath().length +
            order.callbackGasLimit();
    }

    // @dev the estimated gas limit for decrease orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteDecreaseOrderGasLimit(
        DataStore dataStore,
        Order.Props memory order
    ) internal view returns (uint256) {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        uint256 swapCount = order.swapPath().length;
        if (order.decreasePositionSwapType() != Order.DecreasePositionSwapType.NoSwap) {
            swapCount += 1;
        }

        return dataStore.getUint(Keys.decreaseOrderGasLimitKey()) + gasPerSwap * swapCount + order.callbackGasLimit();
    }

    // @dev the estimated gas limit for swap orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteSwapOrderGasLimit(
        DataStore dataStore,
        Order.Props memory order
    ) internal view returns (uint256) {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        return
            dataStore.getUint(Keys.swapOrderGasLimitKey()) +
            gasPerSwap *
            order.swapPath().length +
            order.callbackGasLimit();
    }

    function emitKeeperExecutionFee(EventEmitter eventEmitter, address keeper, uint256 executionFeeAmount) internal {
        EventUtils.EventLogData memory eventData;

        eventData.addressItems.initItems(1);
        eventData.addressItems.setItem(0, "keeper", keeper);

        eventData.uintItems.initItems(1);
        eventData.uintItems.setItem(0, "executionFeeAmount", executionFeeAmount);

        eventEmitter.emitEventLog1("KeeperExecutionFee", Cast.toBytes32(keeper), eventData);
    }

    function emitExecutionFeeRefund(EventEmitter eventEmitter, address receiver, uint256 refundFeeAmount) internal {
        EventUtils.EventLogData memory eventData;

        eventData.addressItems.initItems(1);
        eventData.addressItems.setItem(0, "receiver", receiver);

        eventData.uintItems.initItems(1);
        eventData.uintItems.setItem(0, "refundFeeAmount", refundFeeAmount);

        eventEmitter.emitEventLog1("ExecutionFeeRefund", Cast.toBytes32(receiver), eventData);
    }
}
