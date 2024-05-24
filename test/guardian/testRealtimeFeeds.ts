import { deployFixture } from "../../utils/fixture";
import { expandDecimals, decimalToFloat } from "../../utils/math";
import { OrderType, getOrderCount, createOrder, executeOrder, getOrderKeys } from "../../utils/order";
import { handleDeposit } from "../../utils/deposit";
import { getPositionCount } from "../../utils/position";
import { expect } from "chai";
import { getSyntheticTokenAddress } from "../../utils/token";
import { encodeRealtimeData, TOKEN_ORACLE_TYPES } from "../../utils/oracle";
import hre from "hardhat";
import * as keys from "../../utils/keys";
import { hashString } from "../../utils/hash";

describe("Guardian.MarketDecrease", () => {
  const { provider } = ethers;

  let fixture;
  let user1;
  let reader, dataStore, solUsdMarket, solAddr, ethUsdMarket, wnt, usdc;

  const getBaseRealtimeData = (block) => {
    return {
      feedId: hashString("feedId"),
      observationsTimestamp: block.timestamp,
      median: expandDecimals(5000, 8),
      bid: expandDecimals(5000, 8),
      ask: expandDecimals(5000, 8),
      blocknumberUpperBound: block.number,
      upperBlockhash: block.hash,
      blocknumberLowerBound: block.number,
      currentBlockTimestamp: block.timestamp,
    };
  };

  beforeEach(async () => {
    fixture = await deployFixture();

    ({ user1 } = fixture.accounts);
    ({ reader, dataStore, solUsdMarket, ethUsdMarket, wnt, usdc } = fixture.contracts);

    solAddr = getSyntheticTokenAddress(hre.network.config.chainId, "SOL");

    await handleDeposit(fixture, {
      create: {
        market: ethUsdMarket,
        longTokenAmount: expandDecimals(10000000, 18),
        shortTokenAmount: expandDecimals(10000000 * 5000, 6),
      },
    });

    await handleDeposit(fixture, {
      create: {
        market: solUsdMarket,
        longTokenAmount: expandDecimals(10000000, 18), // ETH
        shortTokenAmount: expandDecimals(10000000 * 5000, 6), // USDC
      },
      execute: {
        tokens: [wnt.address, usdc.address, solAddr],
        tokenOracleTypes: [TOKEN_ORACLE_TYPES.DEFAULT, TOKEN_ORACLE_TYPES.DEFAULT, TOKEN_ORACLE_TYPES.DEFAULT],
        precisions: [8, 18, 18],
        minPrices: [expandDecimals(2500, 4), expandDecimals(1, 6), expandDecimals(15, 6)],
        maxPrices: [expandDecimals(2500, 4), expandDecimals(1, 6), expandDecimals(15, 6)],
      },
    });
  });

  it("Order executes with realtime feed tokens only", async () => {
    const initialUSDCBalance = expandDecimals(50 * 1000, 6); // 50,000 USDC
    expect(await getOrderCount(dataStore)).eq(0);
    await dataStore.setBytes32(keys.realtimeFeedIdKey(wnt.address), hashString("WNT"));
    await dataStore.setUint(keys.realtimeFeedMultiplierKey(wnt.address), expandDecimals(1, 34));
    await dataStore.setBytes32(keys.realtimeFeedIdKey(usdc.address), hashString("USDC"));
    await dataStore.setUint(keys.realtimeFeedMultiplierKey(usdc.address), expandDecimals(1, 46));

    const increaseParams = {
      account: user1,
      market: ethUsdMarket,
      minOutputAmount: 0,
      initialCollateralToken: usdc,
      initialCollateralDeltaAmount: initialUSDCBalance,
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000), // 4x leverage -- position size is 40 ETH @ $5,000/ETH
      acceptablePrice: expandDecimals(5001, 12),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, increaseParams);

    let orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    let order = await reader.getOrder(dataStore.address, orderKey);

    let block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    let baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      tokens: [],
      realtimeFeedTokens: [wnt.address, usdc.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5002, 8),
        }),
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("USDC"),
          bid: expandDecimals(1, 8),
          ask: expandDecimals(1, 8),
        }),
      ],
      expectedCancellationReason: "OrderNotFulfillableAtAcceptablePrice",
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(0);

    await createOrder(fixture, increaseParams);

    expect(await getOrderCount(dataStore)).to.eq(1);
    expect(await getPositionCount(dataStore)).to.eq(0);

    orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    order = await reader.getOrder(dataStore.address, orderKey);

    block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      tokens: [],
      realtimeFeedTokens: [wnt.address, usdc.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5000, 8),
        }),
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("USDC"),
          bid: expandDecimals(1, 8),
          ask: expandDecimals(1, 8),
        }),
      ],
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(1);
  });

  it("Order executes with regular and realtime feed tokens", async () => {
    const initialUSDCBalance = expandDecimals(50 * 1000, 6); // 50,000 USDC
    expect(await getOrderCount(dataStore)).eq(0);
    await dataStore.setBytes32(keys.realtimeFeedIdKey(wnt.address), hashString("WNT"));
    await dataStore.setUint(keys.realtimeFeedMultiplierKey(wnt.address), expandDecimals(1, 34));

    const increaseParams = {
      account: user1,
      market: ethUsdMarket,
      minOutputAmount: 0,
      initialCollateralToken: usdc,
      initialCollateralDeltaAmount: initialUSDCBalance,
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000), // 4x leverage -- position size is 40 ETH @ $5,000/ETH
      acceptablePrice: expandDecimals(5001, 12),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, increaseParams);

    let orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    let order = await reader.getOrder(dataStore.address, orderKey);

    let block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    let baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      tokens: [usdc.address],
      realtimeFeedTokens: [wnt.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5002, 8),
        }),
      ],
      minPrices: [expandDecimals(1, 6)],
      maxPrices: [expandDecimals(1, 6)],
      precisions: [18],
      expectedCancellationReason: "OrderNotFulfillableAtAcceptablePrice",
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(0);

    await createOrder(fixture, increaseParams);

    expect(await getOrderCount(dataStore)).to.eq(1);
    expect(await getPositionCount(dataStore)).to.eq(0);

    orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    order = await reader.getOrder(dataStore.address, orderKey);

    block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      tokens: [usdc.address],
      realtimeFeedTokens: [wnt.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5000, 8),
        }),
      ],
      minPrices: [expandDecimals(1, 6)],
      maxPrices: [expandDecimals(1, 6)],
      precisions: [18],
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(1);
  });

  it("Order executes with regular CL feeds and realtime feed tokens", async () => {
    const initialUSDCBalance = expandDecimals(50 * 1000, 6); // 50,000 USDC
    expect(await getOrderCount(dataStore)).eq(0);
    await dataStore.setBytes32(keys.realtimeFeedIdKey(wnt.address), hashString("WNT"));
    await dataStore.setUint(keys.realtimeFeedMultiplierKey(wnt.address), expandDecimals(1, 34));

    const increaseParams = {
      account: user1,
      market: ethUsdMarket,
      minOutputAmount: 0,
      initialCollateralToken: usdc,
      initialCollateralDeltaAmount: initialUSDCBalance,
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000), // 4x leverage -- position size is 40 ETH @ $5,000/ETH
      acceptablePrice: expandDecimals(5001, 12),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, increaseParams);

    let orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    let order = await reader.getOrder(dataStore.address, orderKey);

    let block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    let baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      tokens: [],
      priceFeedTokens: [usdc.address],
      realtimeFeedTokens: [wnt.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5002, 8),
        }),
      ],
      expectedCancellationReason: "OrderNotFulfillableAtAcceptablePrice",
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(0);

    await createOrder(fixture, increaseParams);

    expect(await getOrderCount(dataStore)).to.eq(1);
    expect(await getPositionCount(dataStore)).to.eq(0);

    orderKey = (await getOrderKeys(dataStore, 0, 1))[0];
    order = await reader.getOrder(dataStore.address, orderKey);

    block = await provider.getBlock(parseInt(order.numbers.updatedAtBlock));
    baseRealtimeData = getBaseRealtimeData(block);

    await executeOrder(fixture, {
      priceFeedTokens: [usdc.address],
      tokens: [],
      realtimeFeedTokens: [wnt.address],
      realtimeFeedData: [
        encodeRealtimeData({
          ...baseRealtimeData,
          feedId: hashString("WNT"),
          bid: expandDecimals(5000, 8),
          ask: expandDecimals(5000, 8),
        }),
      ],
    });

    expect(await getOrderCount(dataStore)).to.eq(0);
    expect(await getPositionCount(dataStore)).to.eq(1);
  });
});
