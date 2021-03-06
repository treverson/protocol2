import * as pjs from "protocol2-js";
import tokenInfos = require("../migrations/config/tokens.js");
import { Artifacts } from "../util/Artifacts";
import { ExchangeTestUtil } from "./testExchangeUtil";

const {
  BrokerRegistry,
  DummyBrokerInterceptor,
} = new Artifacts(artifacts);

contract("Exchange_Broker", (accounts: string[]) => {

  let exchangeTestUtil: ExchangeTestUtil;

  let dummyBrokerInterceptor: any;
  const allTokenSymbols = tokenInfos.development.map((t) => t.symbol);

  before( async () => {
    exchangeTestUtil = new ExchangeTestUtil();
    await exchangeTestUtil.initialize(accounts);

    dummyBrokerInterceptor = await DummyBrokerInterceptor.deployed();
  });

  describe("Broker", () => {

    // Start each test case with a clean trade history otherwise state changes
    // would persist between test cases which would be hard to keep track of and
    // could potentially hide bugs
    beforeEach(async () => {
      await exchangeTestUtil.cleanTradeHistory();
    });

    it("should be able for an order to use a broker without an interceptor", async () => {
      const broker = exchangeTestUtil.testContext.brokers[0];
      const ringsInfo: pjs.RingsInfo = {
        rings: [[0, 1]],
        orders: [
          {
            tokenS: allTokenSymbols[0],
            tokenB: allTokenSymbols[1],
            amountS: 35e17,
            amountB: 22e17,
            broker,
          },
          {
            tokenS: allTokenSymbols[1],
            tokenB: allTokenSymbols[0],
            amountS: 23e17,
            amountB: 31e17,
          },
        ],
      };
      await exchangeTestUtil.setupRings(ringsInfo);

      const owner = ringsInfo.orders[0].owner;
      const emptyAddr = "0x0000000000000000000000000000000000000000";

      // Broker not registered: submitRings should NOT throw, but no transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert.equal(report.transferItems.length, 0, "No tokens should be transfered");
      }

      // Register the broker without interceptor
      await exchangeTestUtil.registerOrderBrokerChecked(owner, broker, emptyAddr);

      // Broker registered: transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert(report.transferItems.length > 0, "Tokens should be transfered");
      }
    });

    it("should be able to for an order to use a broker with an interceptor", async () => {
      const broker = exchangeTestUtil.testContext.brokers[0];
      const ringsInfo: pjs.RingsInfo = {
        rings: [[0, 1]],
        orders: [
          {
            tokenS: allTokenSymbols[1],
            tokenB: allTokenSymbols[2],
            amountS: 35e17,
            amountB: 22e17,
          },
          {
            tokenS: allTokenSymbols[2],
            tokenB: allTokenSymbols[1],
            amountS: 23e17,
            amountB: 31e17,
            broker,
          },
        ],
      };
      await exchangeTestUtil.setupRings(ringsInfo);

      const orderIndex = 1;
      const owner = ringsInfo.orders[orderIndex].owner;
      const tokenS = ringsInfo.orders[orderIndex].tokenS;
      const amountS = ringsInfo.orders[orderIndex].amountS;

      // Broker not registered: submitRings should NOT throw, but no transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert.equal(report.transferItems.length, 0, "No tokens should be transfered");
      }

      // Register the broker with interceptor
      await exchangeTestUtil.registerOrderBrokerChecked(owner, broker, dummyBrokerInterceptor.address);

      // Make sure allowance is set to 0
      await dummyBrokerInterceptor.setAllowance(0e17);

      // Broker registered, but allowance is set to 0 so no transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert.equal(report.transferItems.length, 0, "No tokens should be transfered");
      }

      // Set allowance to something less than amountS
      await dummyBrokerInterceptor.setAllowance(amountS / 3);

      // Broker registered, allowance is set to non-zero so transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert(report.transferItems.length > 0, "Tokens should be transfered");
      }

      // Now set the allowance large enough so that the complete order can be fulfilled
      await dummyBrokerInterceptor.setAllowance(amountS);

      // Broker registered and allowance set to a high value: transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert(report.transferItems.length > 0, "Tokens should be transfered");
      }

      // Check if onTokenSpent was correctly called
      const spendS = (await dummyBrokerInterceptor.spent(owner, tokenS)).toNumber();
      exchangeTestUtil.assertNumberEqualsWithPrecision(spendS, amountS);
    });

    it("an order using a broker with an invalid interceptor should not fail the transaction", async () => {
      const broker = exchangeTestUtil.testContext.brokers[0];
      const ringsInfo: pjs.RingsInfo = {
        rings: [[0, 1]],
        orders: [
          {
            tokenS: allTokenSymbols[0],
            tokenB: allTokenSymbols[1],
            amountS: 35e17,
            amountB: 22e17,
          },
          {
            tokenS: allTokenSymbols[1],
            tokenB: allTokenSymbols[0],
            amountS: 23e17,
            amountB: 31e17,
            broker,
          },
        ],
      };
      await exchangeTestUtil.setupRings(ringsInfo);

      const owner = ringsInfo.orders[1].owner;
      const invalidInterceptorAddress = BrokerRegistry.address;

      // Register the broker with interceptor
      await exchangeTestUtil.registerOrderBrokerChecked(owner, broker, invalidInterceptorAddress);

      // Broker registered with invalid interceptor, should NOT throw but allowance will be set to 0
      // so no transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert.equal(report.transferItems.length, 0, "No tokens should be transfered");
      }

      // Unregister the broker
      await exchangeTestUtil.unregisterOrderBrokerChecked(owner, broker);

      // Register the broker with interceptor
      await exchangeTestUtil.registerOrderBrokerChecked(owner, broker, dummyBrokerInterceptor.address);

      // Now set the allowance to a large number
      await dummyBrokerInterceptor.setAllowance(1e32);

      // Let all functions fail
      await dummyBrokerInterceptor.setFailAllFunctions(true);

      // Broker registered with interceptor functions erroring out, should NOT throw but allowance will be set to 0
      // so no transactions should happen
      {
        const {tx, report} = await exchangeTestUtil.submitRingsAndSimulate(ringsInfo);
        assert.equal(report.transferItems.length, 0, "No tokens should be transfered");
      }
    });

  });

});
