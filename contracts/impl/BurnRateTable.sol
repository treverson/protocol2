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

import "../iface/Errors.sol";
import "../iface/IBurnRateTable.sol";
import "../lib/BurnableERC20.sol";
import "../lib/MathUint.sol";
import "../lib/NoDefaultFunc.sol";

/// @author Brecht Devos - <brecht@loopring.org>
contract BurnRateTable is IBurnRateTable, NoDefaultFunc, Errors {
    using MathUint for uint;

    address public lrcAddress = 0x0;
    address public wethAddress = 0x0;

    constructor(
        address _lrcAddress,
        address _wethAddress
        )
        public
    {
        require(_lrcAddress != 0x0, ZERO_ADDRESS);
        require(_wethAddress != 0x0, ZERO_ADDRESS);
        lrcAddress = _lrcAddress;
        wethAddress = _wethAddress;

        // Set fixed LRC and WETH burn rates
        setFixedTokenTier(lrcAddress, TIER_1);
        setFixedTokenTier(wethAddress, TIER_3);
    }

    function setFixedTokenTier(
        address token,
        uint tier
        )
        internal
    {
        TokenData storage tokenData = tokens[token];
        tokenData.validUntil = ~uint(0);
        tokenData.tier = tier;
    }

    function getBurnRate(
        address token
        )
        external
        view
        returns (uint32 burnRate)
    {
        uint tier = getTokenTier(token);
        if (tier == TIER_1) {
            burnRate = uint32(BURN_P2P_TIER1) * 0x10000 + BURN_MATCHING_TIER1;
        } else if (tier == TIER_2) {
            burnRate = uint32(BURN_P2P_TIER2) * 0x10000 + BURN_MATCHING_TIER2;
        } else if (tier == TIER_3) {
            burnRate = uint32(BURN_P2P_TIER3) * 0x10000 + BURN_MATCHING_TIER3;
        } else {
            burnRate = uint32(BURN_P2P_TIER4) * 0x10000 + BURN_MATCHING_TIER4;
        }
    }

    function upgradeTokenTier(
        address token
        )
        external
        returns (bool)
    {
        require(token != 0x0, ZERO_ADDRESS);
        require(token != lrcAddress, BURN_RATE_FROZEN);
        require(token != wethAddress, BURN_RATE_FROZEN);

        uint currentTier = getTokenTier(token);

        // Can't upgrade to a higher level than tier 1
        require(currentTier != TIER_1, BURN_RATE_MINIMIZED);

        // Burn TIER_UPGRADE_COST_PERCENTAGE of total LRC supply
        BurnableERC20 LRC = BurnableERC20(lrcAddress);
        uint totalSupply = LRC.totalSupply();
        uint amount = totalSupply.mul(TIER_UPGRADE_COST_PERCENTAGE) / BURN_BASE_PERCENTAGE;
        bool success = LRC.burnFrom(msg.sender, amount);
        require(success, BURN_FAILURE);

        // Upgrade tier
        TokenData storage tokenData = tokens[token];
        tokenData.validUntil = now.add(2 * YEAR_TO_SECONDS);
        tokenData.tier = currentTier + 1;

        emit TokenTierUpgraded(token, tokenData.tier);

        return true;
    }

    function getTokenTier(
        address token
        )
        public
        view
        returns (uint tier)
    {
        TokenData storage tokenData = tokens[token];
        // Fall back to lowest tier
        tier = (now > tokenData.validUntil) ? TIER_4 : tokenData.tier;
    }

    function getRebateRate(
        address user
        )
        public
        view
        returns (uint16)
    {
        UserData storage userData = balances[user];
        if (userData.lockedSince + LOCK_TIME < now) {
            return uint16(0);
        }

        uint totalSupply = BurnableERC20(lrcAddress).totalSupply();
        uint maxLockAmount = totalSupply.mul(MAX_LOCK_PERCENTAGE) / LOCK_BASE_PERCENTAGE;

        uint rebatePercentage = userData.amount.mul(BURN_BASE_PERCENTAGE) / maxLockAmount;
        rebatePercentage = (rebatePercentage > BURN_BASE_PERCENTAGE) ? BURN_BASE_PERCENTAGE : rebatePercentage;
        return uint16(rebatePercentage);
    }

    function lock(
        uint amount
        )
        external
        returns (bool)
    {
        require(amount > 0, INVALID_VALUE);

        UserData storage userData = balances[msg.sender];

        // If the user only has unlocked tokens he first needs to withdraw them.
        // It doesn't make any sense to change the lock start time stamp if the new amount
        // that should be locked is immediately unlocked because the new start time stamp is still
        // below the lock duration period.
        if (userData.amount > 0) {
            uint withdrawableAmount = getWithdrawableBalance(msg.sender);
            require(
                userData.amount != withdrawableAmount,
                INVALID_STATE
            );
        }

        BurnableERC20 LRC = BurnableERC20(lrcAddress);
        bool success = LRC.transferFrom(msg.sender, this, amount);
        require(success, TRANSFER_FAILURE);

        // The lock time is updated by weighting the extra amount with the new total amount
        // newLockedTime := oldLockedTime + ((now - oldLockedTime) * (amount / newAmount))
        uint newAmount = userData.amount.add(amount);
        uint timeDelta = now.sub(userData.lockedSince);
        uint weightedTimeDelta = timeDelta.mul(amount) / newAmount;
        uint newLockTime = userData.lockedSince.add(weightedTimeDelta);

        userData.amount = newAmount;
        userData.lockedSince = newLockTime;
        // Reset withdrawnAmount
        userData.amountWithdrawn = 0;

        return true;
    }

    function withdraw(
        uint amount
        )
        external
        returns (bool)
    {
        require(amount > 0, ZERO_VALUE);

        uint withdrawableAmount = getWithdrawableBalance(msg.sender);
        require(withdrawableAmount >= amount, INVALID_VALUE);

        BurnableERC20 LRC = BurnableERC20(lrcAddress);
        bool success = LRC.transfer(msg.sender, amount);
        require(success, TRANSFER_FAILURE);

        UserData storage userData = balances[msg.sender];
        userData.amount = userData.amount.sub(amount);
        userData.amountWithdrawn = userData.amountWithdrawn.add(amount);

        return true;
    }

    function getBalance(
        address user
        )
        external
        view
        returns (uint)
    {
        UserData storage userData = balances[user];
        return userData.amount;
    }

    function getWithdrawableBalance(
        address user
        )
        public
        view
        returns (uint)
    {
        UserData storage userData = balances[user];

        uint initialAmount = userData.amount.add(userData.amountWithdrawn);
        uint withdrawableAmount = 0;

        uint timeDelta = now.sub(userData.lockedSince);
        if (timeDelta < LINEAR_UNLOCK_START_TIME) {
            withdrawableAmount = 0;
        } else if (timeDelta >= LOCK_TIME) {
            withdrawableAmount = initialAmount;
        } else {
            uint progress = timeDelta.sub(LINEAR_UNLOCK_START_TIME);
            // Linear unlock between LINEAR_UNLOCK_START_TIME and LOCK_TIME on the initial locked amount
            withdrawableAmount = initialAmount.mul(progress) / (LOCK_TIME - LINEAR_UNLOCK_START_TIME);
        }

        // Subtract the part that was already withdrawn
        withdrawableAmount = withdrawableAmount.sub(userData.amountWithdrawn);

        return withdrawableAmount;
    }

    function getLockStartTime(
        address user
        )
        external
        view
        returns (uint)
    {
        UserData storage userData = balances[user];
        return userData.lockedSince;
    }

}
