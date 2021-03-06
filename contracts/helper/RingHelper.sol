/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/
pragma solidity 0.4.24;
pragma experimental "v0.5.0";
pragma experimental "ABIEncoderV2";

import "../iface/IRingSubmitter.sol";
import "../impl/BrokerInterceptorProxy.sol";
import "../impl/Data.sol";
import "../lib/ERC20.sol";
import "../lib/MathUint.sol";
import "../lib/MultihashUtil.sol";
import "./OrderHelper.sol";
import "./ParticipationHelper.sol";


/// @title RingHelper
library RingHelper {
    using MathUint for uint;
    using OrderHelper for Data.Order;
    using ParticipationHelper for Data.Participation;

    using BrokerInterceptorProxy for address;
    function updateHash(
        Data.Ring ring
        )
        internal
        pure
    {
        uint ringSize = ring.size;
        bytes32 hash;
        assembly {
            let data := mload(0x40)
            let ptr := data
            for { let i := 0 } lt(i, ringSize) { i := add(i, 1) } {
                let participations := mload(add(ring, 32))
                let order := mload(mload(add(participations, add(32, mul(i, 32)))))

                let waiveFeePercentage := and(mload(add(order, 672)), 0xFFFF)
                let orderHash := mload(add(order, 864))

                mstore(add(ptr, 2), waiveFeePercentage)
                mstore(ptr, orderHash)

                ptr := add(ptr, 34)
            }
            hash := keccak256(data, sub(ptr, data))
        }
        ring.hash = hash;
    }

    function calculateFillAmountAndFee(
        Data.Ring ring,
        Data.Context ctx
        )
        internal
    {
        // Invalid order data could cause a divide by zero in the calculations
        if (!ring.valid) {
            return;
        }

        uint i;
        int j;
        uint prevIndex;

        for (i = 0; i < ring.size; i++) {
            ring.participations[i].setMaxFillAmounts(
                ctx
            );
        }

        uint smallest = 0;
        for (j = int(ring.size) - 1; j >= 0; j--) {
            prevIndex = (uint(j) + ring.size - 1) % ring.size;
            smallest = calculateOrderFillAmounts(
                ctx,
                ring.participations[uint(j)],
                ring.participations[prevIndex],
                uint(j),
                smallest
            );
        }
        for (j = int(ring.size) - 1; j >= int(smallest); j--) {
            prevIndex = (uint(j) + ring.size - 1) % ring.size;
            calculateOrderFillAmounts(
                ctx,
                ring.participations[uint(j)],
                ring.participations[prevIndex],
                uint(j),
                smallest
            );
        }

        // Reserve the total amount tokenS used for all the orders
        // (e.g. the owner of order 0 could use LRC as feeToken in order 0, while
        // the same owner can also sell LRC in order 2).
        for (i = 0; i < ring.size; i++) {
            ring.participations[i].order.reserveAmountS(ring.participations[i].fillAmountS);
        }

        for (i = 0; i < ring.size; i++) {
            prevIndex = (i + ring.size - 1) % ring.size;

            // Check if this order needs to be completely filled
            if(ring.participations[i].order.allOrNone &&
               ring.participations[i].fillAmountB != ring.participations[i].order.amountB) {
                ring.valid = false;
                break;
            }

            bool valid = ring.participations[i].calculateFees(ring.participations[prevIndex], ctx);
            if (!valid) {
                ring.valid = false;
                break;
            }

            int16 waiveFeePercentage = ring.participations[i].order.waiveFeePercentage;
            if (waiveFeePercentage < 0) {
                ring.minerFeesToOrdersPercentage += uint(-waiveFeePercentage);
            }
        }
        // Miner can only distribute 100% of its fees to all orders combined
        ring.valid = ring.valid && (ring.minerFeesToOrdersPercentage <= ctx.feePercentageBase);

        // Ring calculations are done. Make sure te remove all spendable reservations for this ring
        for (i = 0; i < ring.size; i++) {
            ring.participations[i].order.resetReservations();
        }
    }

    function calculateOrderFillAmounts(
        Data.Context ctx,
        Data.Participation p,
        Data.Participation prevP,
        uint i,
        uint smallest
        )
        internal
        pure
        returns (uint smallest_)
    {
        // Default to the same smallest index
        smallest_ = smallest;

        uint postFeeFillAmountS = p.fillAmountS;
        uint tokenSFeePercentage = p.order.tokenSFeePercentage;
        if (tokenSFeePercentage > 0) {
            postFeeFillAmountS = p.fillAmountS
                .mul(ctx.feePercentageBase - tokenSFeePercentage) / ctx.feePercentageBase;
        }

        if (prevP.fillAmountB > postFeeFillAmountS) {
            smallest_ = i;
            prevP.fillAmountB = postFeeFillAmountS;
            prevP.fillAmountS = postFeeFillAmountS.mul(prevP.order.amountS) / prevP.order.amountB;
        }
    }

    function checkOrdersValid(
        Data.Ring ring
        )
        internal
        pure
    {
        ring.valid = ring.valid && (ring.size > 1 && ring.size <= 8); // invalid ring size
        for (uint i = 0; i < ring.size; i++) {
            ring.valid = ring.valid && ring.participations[i].order.valid;
        }
    }

    function checkForSubRings(
        Data.Ring ring
        )
        internal
        pure
    {
        for (uint i = 0; i < ring.size - 1; i++) {
            address tokenS = ring.participations[i].order.tokenS;
            for (uint j = i + 1; j < ring.size; j++) {
                ring.valid = ring.valid && (tokenS != ring.participations[j].order.tokenS);
            }
        }
    }

    function settleRing(
        Data.Ring ring,
        Data.Context ctx,
        Data.Mining mining
        )
        internal
    {
        payFees(ring, ctx, mining);
        transferTokens(ring, ctx);

        // Adjust the orders
        for (uint i = 0; i < ring.size; i++) {
            ring.participations[i].adjustOrderState();
        }
    }

    function generateFills(
        Data.Ring ring
        )
        internal
        pure
        returns (IRingSubmitter.Fill[] memory fills)
    {
        uint ringSize = ring.size;
        uint arrayDataSize = (ringSize + 1) * 32;
        assembly {
            fills := mload(0x40)
            mstore(add(fills, 0), ringSize)
            let fill := add(fills, arrayDataSize)
            let participations := mload(add(ring, 32))                                  // participations

            for { let i := 0 } lt(i, ringSize) { i := add(i, 1) } {
                // Store the memory location of this fill in the fills array
                mstore(add(fills, mul(add(i, 1), 32)), fill)

                let participation := mload(add(participations, add(32, mul(i, 32))))
                let order := mload(participation)

                mstore(add(fill,   0), mload(add(order, 864)))                           // hash
                mstore(add(fill,  32), mload(add(order,   0)))                           // owner
                mstore(add(fill,  64), mload(add(order,  32)))                           // tokenS
                mstore(add(fill,  96), mload(add(participation, 256)))                   // fillAmountS
                mstore(add(fill, 128), mload(add(participation,  32)))                   // splitS
                mstore(add(fill, 160), mload(add(participation,  64)))                   // feeAmount

                fill := add(fill, 192)
            }
            mstore(0x40, fill)
        }
    }

    function transferTokens(
        Data.Ring ring,
        Data.Context ctx
        )
        internal
    {
        bytes4 batchTransferSelector = ctx.delegate.batchTransfer.selector;
        address tradeDelegateAddress = address(ctx.delegate);
        uint data;
        uint ptr;
        assembly {
            data := mload(0x40)
            mstore(data, batchTransferSelector)
            mstore(add(data, 4), 32)
            ptr := add(data, 68)
            mstore(0x40, add(ptr, mul(mul(mload(ring), 12), 32)))
        }
        for (uint i = 0; i < ring.size; i++) {
            ptr = transferTokensForParticipation(
                ptr,
                ctx,
                ring.participations[i],
                ring.participations[(i + ring.size - 1) % ring.size]
            );
        }
        assembly {
            mstore(add(data, 36), div(sub(ptr, add(data, 68)), 32))             // length

            let success := call(
                gas,                                // forward all gas
                tradeDelegateAddress,               // external address
                0,                                  // wei
                data,                               // input start
                sub(ptr, data),                     // input length
                data,                               // output start
                32                                  // output length
            )
            if eq(success, 0) {
                revert(0, 0)
            }
        }
    }

    function transferTokensForParticipation(
        uint ptr,
        Data.Context ctx,
        Data.Participation p,
        Data.Participation prevP
        )
        internal
        returns (uint)
    {
        uint buyerFeeAmountAfterRebateB = prevP.feeAmountB.sub(prevP.rebateB);

        // If the buyer needs to pay fees in tokenB, the seller needs
        // to send the tokenS amount to the fee holder contract
        uint amountSToBuyer = p.fillAmountS
            .sub(p.feeAmountS)
            .sub(buyerFeeAmountAfterRebateB);

        uint amountSToFeeHolder = p.feeAmountS
            .sub(p.rebateS)
            .add(buyerFeeAmountAfterRebateB)
            .add(p.splitS);

        uint amountFeeToFeeHolder = p.feeAmount
            .sub(p.rebateFee);

        if (p.order.tokenS == p.order.feeToken) {
            amountSToFeeHolder += amountFeeToFeeHolder;
            amountFeeToFeeHolder = 0;
        }

        // Transfers
        ptr = addTokenTransfer(
            ptr,
            p.order.tokenS,
            p.order.owner,
            prevP.order.tokenRecipient,
            amountSToBuyer
        );
        ptr = addTokenTransfer(
            ptr,
            p.order.tokenS,
            p.order.owner,
            address(ctx.feeHolder),
            amountSToFeeHolder
        );
        ptr = addTokenTransfer(
            ptr,
            p.order.feeToken,
            p.order.owner,
            address(ctx.feeHolder),
            amountFeeToFeeHolder
        );

        // onTokenSpent broker callbacks
        if (p.order.brokerInterceptor != 0x0) {
            onTokenSpent(
                p.order.brokerInterceptor,
                p.order.owner,
                p.order.broker,
                p.order.tokenS,
                amountSToBuyer + amountSToFeeHolder
            );
            onTokenSpent(
                p.order.brokerInterceptor,
                p.order.owner,
                p.order.broker,
                p.order.feeToken,
                amountFeeToFeeHolder
            );
        }

        return ptr;
    }

    function addTokenTransfer(
        uint ptr,
        address token,
        address from,
        address to,
        uint amount
        )
        internal
        pure
        returns (uint)
    {
        if (amount > 0 && from != to) {
            assembly {
                mstore(add(ptr,  0), token)
                mstore(add(ptr, 32), from)
                mstore(add(ptr, 64), to)
                mstore(add(ptr, 96), amount)
            }
            return ptr + 128;
        } else {
            return ptr;
        }
    }

    function onTokenSpent(
        address brokerInterceptor,
        address owner,
        address broker,
        address token,
        uint    amount
        )
        internal
    {
        if (brokerInterceptor == 0x0 || amount == 0) {
            return;
        } else {
            brokerInterceptor.onTokenSpentSafe(
                owner,
                broker,
                token,
                amount
            );
        }
    }

    function payFees(
        Data.Ring ring,
        Data.Context ctx,
        Data.Mining mining
        )
        internal
    {
        uint maxSize = (ring.size + 3) * 3 * ring.size * 3;
        bytes4 batchAddFeeBalancesSelector = ctx.feeHolder.batchAddFeeBalances.selector;
        address feeHolderAddress = address(ctx.feeHolder);
        uint data;
        uint ptr;
        assembly {
            data := mload(0x40)
            mstore(data, batchAddFeeBalancesSelector)
            mstore(add(data, 4), 32)
            ptr := add(data, 68)
            mstore(0x40, add(ptr, mul(maxSize, 32)))
        }

        Data.FeeContext memory feeCtx;
        feeCtx.data = ptr;
        feeCtx.ptr = ptr;
        feeCtx.ring = ring;
        feeCtx.ctx = ctx;
        feeCtx.feeRecipient = mining.feeRecipient;
        for (uint i = 0; i < ring.size; i++) {
            payFeesForParticipation(
                feeCtx,
                ring.participations[i]
            );
        }
        ptr = feeCtx.ptr;

        assembly {
            mstore(add(data, 36), div(sub(ptr, add(data, 68)), 32))             // length

            let success := call(
                gas,                                // forward all gas
                feeHolderAddress,                   // external address
                0,                                  // wei
                data,                               // input start
                sub(ptr, data),                     // input length
                data,                               // output start
                32                                  // output length
            )
            if eq(success, 0) {
                revert(0, 0)
            }
        }
    }

    function payFeesForParticipation(
        Data.FeeContext memory feeCtx,
        Data.Participation memory p
        )
        internal
        view
        returns (uint)
    {
        uint walletPercentage = p.order.P2P ? 100 : (p.order.wallet == 0x0 ? 0 : p.order.walletSplitPercentage);
        feeCtx.walletPercentage = walletPercentage;

        feeCtx.waiveFeePercentage = p.order.waiveFeePercentage;
        feeCtx.owner = p.order.owner;
        feeCtx.wallet = p.order.wallet;
        feeCtx.P2P = p.order.P2P;

        p.rebateFee = payFeesAndBurn(
            feeCtx,
            p.order.feeToken,
            p.feeAmount,
            0
        );
        p.rebateS = payFeesAndBurn(
            feeCtx,
            p.order.tokenS,
            p.feeAmountS,
            p.splitS
        );
        p.rebateB = payFeesAndBurn(
            feeCtx,
            p.order.tokenB,
            p.feeAmountB,
            0
        );
    }

    function payFeesAndBurn(
        Data.FeeContext memory feeCtx,
        address token,
        uint amount,
        uint margin
        )
        internal
        view
        returns (uint)
    {
        if (amount + margin == 0) {
            return 0;
        }

        uint feeToWallet = 0;
        uint minerFee = 0;
        uint minerFeeBurn = 0;
        uint walletFeeBurn = 0;
        if (amount > 0) {
            feeToWallet = amount.mul(feeCtx.walletPercentage) / 100;
            minerFee = amount - feeToWallet;

            // Miner can waive fees for this order. If waiveFeePercentage > 0 this is a simple reduction in fees.
            if (feeCtx.waiveFeePercentage > 0) {
                minerFee = minerFee.mul(
                    feeCtx.ctx.feePercentageBase - uint(feeCtx.waiveFeePercentage)) /
                    feeCtx.ctx.feePercentageBase;
            } else if (feeCtx.waiveFeePercentage < 0) {
                // No fees need to be paid by this order
                minerFee = 0;
            }

            uint32 burnRate = getBurnRate(feeCtx, token);

            // Miner fee
            minerFeeBurn = minerFee.mul(burnRate) / feeCtx.ctx.feePercentageBase;
            minerFee = minerFee - minerFeeBurn;
            // Wallet fee
            walletFeeBurn = feeToWallet.mul(burnRate) / feeCtx.ctx.feePercentageBase;
            feeToWallet = feeToWallet - walletFeeBurn;
        }
        // Miner gets the margin without sharing it with the wallet or burning
        minerFee += margin;

        // Fees can be paid out in different tokens so we can't easily accumulate the total fee
        // that needs to be paid out to order owners. So we pay out each part out here to all
        // orders that need it.
        uint feeToMiner = minerFee;
        if (feeCtx.ring.minerFeesToOrdersPercentage > 0 && minerFee > 0) {
            // Pay out the fees to the orders
            distributeMinerFeeToOwners(
                feeCtx,
                token,
                minerFee
            );
            // Subtract all fees the miner pays to the orders
            feeToMiner = minerFee.mul(feeCtx.ctx.feePercentageBase -
                feeCtx.ring.minerFeesToOrdersPercentage) /
                feeCtx.ctx.feePercentageBase;
        }

        feeCtx.ptr = addFeePayment(
            feeCtx.data,
            feeCtx.ptr,
            token,
            feeCtx.wallet,
            feeToWallet
        );
        feeCtx.ptr = addFeePayment(
            feeCtx.data,
            feeCtx.ptr,
            token,
            feeCtx.feeRecipient,
            feeToMiner
        );
        // Pay the burn rate with the feeHolder as owner
        feeCtx.ptr = addFeePayment(
            feeCtx.data,
            feeCtx.ptr,
            token,
            address(feeCtx.ctx.feeHolder),
            minerFeeBurn + walletFeeBurn
        );

        // Calculate the total fee payment after possible discounts (burn rebate + fee waiving)
        // and return the total rebate
        return (amount + margin).sub((feeToWallet + minerFee) + (minerFeeBurn + walletFeeBurn));
    }

    function getBurnRate(
        Data.FeeContext memory feeCtx,
        address token
        )
        internal
        view
        returns (uint32)
    {
        bytes32[] memory tokenBurnRates = feeCtx.ctx.tokenBurnRates;
        uint length = tokenBurnRates.length;
        for (uint i = 0; i < length; i += 2) {
            if (token == address(tokenBurnRates[i])) {
                uint32 burnRate = uint32(tokenBurnRates[i + 1]);
                return feeCtx.P2P ? (burnRate / 0x10000) : (burnRate & 0xFFFF);
            }
        }
        // Not found, add it to the list
        uint32 burnRate = feeCtx.ctx.burnRateTable.getBurnRate(token);
        assembly {
            let ptr := add(tokenBurnRates, mul(add(1, length), 32))
            mstore(ptr, token)                              // Token
            mstore(add(ptr, 32), burnRate)                  // Burn rate
            mstore(tokenBurnRates, add(length, 2))          // Lenght
        }
        return feeCtx.P2P ? (burnRate / 0x10000) : (burnRate & 0xFFFF);
    }

    function distributeMinerFeeToOwners(
        Data.FeeContext memory feeCtx,
        address token,
        uint minerFee
        )
        internal
        pure
    {
        for (uint i = 0; i < feeCtx.ring.size; i++) {
            Data.Participation memory p = feeCtx.ring.participations[i];
            if (p.order.waiveFeePercentage < 0) {
                uint feeToOwner = minerFee
                    .mul(uint(-p.order.waiveFeePercentage)) / feeCtx.ctx.feePercentageBase;

                feeCtx.ptr = addFeePayment(
                    feeCtx.data,
                    feeCtx.ptr,
                    token,
                    p.order.owner,
                    feeToOwner);
            }
        }
    }

    function addFeePayment(
        uint data,
        uint ptr,
        address token,
        address owner,
        uint amount
        )
        internal
        pure
        returns (uint)
    {
        if (amount == 0) {
            return ptr;
        } else {
            // Try to find an existing fee payment of the same token to the same owner
            for (uint p = data; p < ptr; p += 96) {
                address dataToken;
                address dataOwner;
                uint dataAmount;
                assembly {
                    dataToken := mload(add(p,  0))
                    dataOwner := mload(add(p, 32))
                    dataAmount := mload(add(p, 64))
                }
                if(token == dataToken && owner == dataOwner) {
                    dataAmount = dataAmount.add(amount);
                    assembly {
                        mstore(add(p,  64), dataAmount)
                    }
                    return ptr;
                }

            }
            assembly {
                mstore(add(ptr,  0), token)
                mstore(add(ptr, 32), owner)
                mstore(add(ptr, 64), amount)
            }
            return ptr + 96;
        }
    }

}
