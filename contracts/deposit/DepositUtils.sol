// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "./DepositVault.sol";
import "./DepositStoreUtils.sol";
import "./DepositEventUtils.sol";

import "../nonce/NonceUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";
import "../utils/AccountUtils.sol";

// @title DepositUtils
// @dev Library for deposit functions, to help with the depositing of liquidity
// into a market in return for market tokens
library DepositUtils {
    using SafeCast for uint256;
    using SafeCast for int256;

    using Price for Price.Props;
    using Deposit for Deposit.Props;

    // @dev CreateDepositParams struct used in createDeposit to avoid stack
    // too deep errors
    //
    // @param receiver the address to send the market tokens to
    // @param callbackContract the callback contract
    // @param uiFeeReceiver the ui fee receiver
    // @param market the market to deposit into
    // @param minMarketTokens the minimum acceptable number of liquidity tokens
    // @param shouldUnwrapNativeToken whether to unwrap the native token when
    // sending funds back to the user in case the deposit gets cancelled
    // @param executionFee the execution fee for keepers
    // @param callbackGasLimit the gas limit for the callbackContract
    struct CreateDepositParams {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialLongToken;
        address initialShortToken;
        address[] longTokenSwapPath;
        address[] shortTokenSwapPath;
        uint256 minMarketTokens;
        bool shouldUnwrapNativeToken;
        uint256 executionFee;
        uint256 callbackGasLimit;
    }

    // @dev creates a deposit
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param account the depositing account
    // @param params CreateDepositParams
    function createDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        address account,
        CreateDepositParams memory params
    ) external returns (bytes32) {
        //验证account地址不能为0
        AccountUtils.validateAccount(account);
        //验证这个市场是否开启
        Market.Props memory market = MarketUtils.getEnabledMarket(dataStore, params.market);
        //校验swap路径是否正确
        MarketUtils.validateSwapPath(dataStore, params.longTokenSwapPath);
        MarketUtils.validateSwapPath(dataStore, params.shortTokenSwapPath);

        // if the initialLongToken and initialShortToken are the same, only the initialLongTokenAmount would
        // be non-zero, the initialShortTokenAmount would be zero
        //如果initialLongToken和initialShortToken相同的话,initialLongTokenAmount 不为0，initialShortTokenAmount应该为0
        //recordTransferIn计算一下本次交易转进来多少代币
        uint256 initialLongTokenAmount = depositVault.recordTransferIn(params.initialLongToken);
        uint256 initialShortTokenAmount = depositVault.recordTransferIn(params.initialShortToken);

        address wnt = TokenUtils.wnt(dataStore);
        //如果是该链的治理代币的Wrap应该扣除执行费
        //检查initialLongToken和initialShortToken是否为治理代币
        //如果是就扣除执行费
        //如果不是,查看一下本笔交易转入的治理代币的金额是否够支付执行费
        //如果不够 则终止交易
        if (params.initialLongToken == wnt) {
            initialLongTokenAmount -= params.executionFee;
        } else if (params.initialShortToken == wnt) {
            initialShortTokenAmount -= params.executionFee;
        } else {
            //应该在muticall 函数将执行费计算好,进行扣除
            uint256 wntAmount = depositVault.recordTransferIn(wnt);
            if (wntAmount < params.executionFee) {
                revert Errors.InsufficientWntAmountForExecutionFee(wntAmount, params.executionFee);
            }

            params.executionFee = wntAmount;
        }
        //如果initialLongTokenAmount和initialShortTokenAmount都为0的话
        //说明没有任何金额进来这个池子，终止交易
        if (initialLongTokenAmount == 0 && initialShortTokenAmount == 0) {
            revert Errors.EmptyDepositAmounts();
        }
        //验证接收者地址不能为0
        AccountUtils.validateReceiver(params.receiver);
        //构造Deposit订单的参数
        Deposit.Props memory deposit = Deposit.Props(
            Deposit.Addresses(
                account,
                params.receiver,
                params.callbackContract,
                params.uiFeeReceiver,
                market.marketToken,
                params.initialLongToken,
                params.initialShortToken,
                params.longTokenSwapPath,
                params.shortTokenSwapPath
            ),
            Deposit.Numbers(
                initialLongTokenAmount,
                initialShortTokenAmount,
                params.minMarketTokens,
                Chain.currentBlockNumber(),
                params.executionFee,
                params.callbackGasLimit
            ),
            Deposit.Flags(params.shouldUnwrapNativeToken)
        );
        //验证不超过 gas Limit
        CallbackUtils.validateCallbackGasLimit(dataStore, deposit.callbackGasLimit());
        //预估一下执行gas
        uint256 estimatedGasLimit = GasUtils.estimateExecuteDepositGasLimit(dataStore, deposit);
        //如果执行费不够支付 gas*gasprice 则终止交易
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, params.executionFee);
        //生成订单key
        bytes32 key = NonceUtils.getNextKey(dataStore);
        //存储到数据库
        DepositStoreUtils.set(dataStore, key, deposit);
        //触发event
        DepositEventUtils.emitDepositCreated(eventEmitter, key, deposit);

        return key;
    }

    // @dev cancels a deposit, funds are sent back to the user
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param key the key of the deposit to cancel
    // @param keeper the address of the keeper
    // @param startingGas the starting gas amount
    function cancelDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Deposit.Props memory deposit = DepositStoreUtils.get(dataStore, key);
        if (deposit.account() == address(0)) {
            revert Errors.EmptyDeposit();
        }

        if (deposit.initialLongTokenAmount() == 0 && deposit.initialShortTokenAmount() == 0) {
            revert Errors.EmptyDepositAmounts();
        }

        DepositStoreUtils.remove(dataStore, key, deposit.account());

        if (deposit.initialLongTokenAmount() > 0) {
            depositVault.transferOut(
                deposit.initialLongToken(),
                deposit.account(),
                deposit.initialLongTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        if (deposit.initialShortTokenAmount() > 0) {
            depositVault.transferOut(
                deposit.initialShortToken(),
                deposit.account(),
                deposit.initialShortTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        DepositEventUtils.emitDepositCancelled(eventEmitter, key, deposit.account(), reason, reasonBytes);

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterDepositCancellation(key, deposit, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            depositVault,
            deposit.executionFee(),
            startingGas,
            keeper,
            deposit.account()
        );
    }
}
